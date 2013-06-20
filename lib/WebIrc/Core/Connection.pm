package WebIrc::Core::Connection;

=head1 NAME

WebIrc::Core::Connection - Represents a connection to an IRC server

=head1 SYNOPSIS

  use WebIrc::Core::Connection;

  $c = WebIrc::Core::Connection->new(
          id => 'foobar',
          redis => Mojo::Redis->new,
        );

  $c->connect;

  Mojo::IOLoop->start;

=head1 DESCRIPTION

This module use L<Mojo::IRC> to set up a connection to an IRC server. The
attributes used to do so is figured out from a redis server.

There are quite a few L<EVENTS|Mojo::IRC/EVENTS> that this module use:

=over 4

=item * L</add_message> events

L<Mojo::IRC/privmsg>.

=item * L</add_server_message> events

L<Mojo::IRC/rpl_yourhost>, L<Mojo::IRC/rpl_motdstart>, L<Mojo::IRC/rpl_motd>,
L<Mojo::IRC/rpl_endofmotd>, L<Mojo::IRC/rpl_welcome> and L<Mojo::IRC/error>.

=item * Other events

L</irc_rpl_welcome>, L</irc_rpl_myinfo>, L</irc_join>, L</irc_part>,
L<irc_rpl_namreply> and l</irc_error>.

=back

=cut

use Mojo::Base -base;
use Mojo::IRC;
no warnings "utf8";
use Mojo::JSON;
use Parse::IRC   ();
use IRC::Utils   ();
use Scalar::Util ();
use Carp qw/ croak /;
use Time::HiRes qw/ time /;
use IRC::Utils qw/parse_user/;
use constant DEBUG => $ENV{WIRC_DEBUG} ? 1 : 0;

my $JSON = Mojo::JSON->new;
my @keys = qw/ nick user host /;

=head1 ATTRIBUTES

=head2 id

Holds the id of this connection. This attribute is required.

=cut

has id => 0;

=head2 redis

Holds a L<Mojo::Redis> object.

=cut

has redis => sub { Mojo::Redis->new(timeout => 0); };

=head2 channels

IRC channels to join. The channel list will be fetched from the L</redis>
server by L</connect>.

=cut

has channels => sub { [] };

=head2 real_host

The actual IRC server connected to. Will be set by L</irc_rpl_welcome>.

=cut

has real_host => '';

=head2 log

Holds a L<Mojo::Log> object.

=cut

has log => sub { Mojo::Log->new };

my @ADD_MESSAGE_EVENTS        = qw/ irc_privmsg /;
my @ADD_SERVER_MESSAGE_EVENTS = qw/
  irc_rpl_yourhost irc_rpl_motdstart irc_rpl_motd irc_rpl_endofmotd
  irc_rpl_welcome
/;
my @OTHER_EVENTS              = qw/
  irc_rpl_welcome irc_rpl_myinfo irc_join irc_nick irc_part irc_rpl_namreply
  irc_error irc_rpl_whoisuser irc_rpl_whoischannels irc_rpl_topic irc_topic
  irc_rpl_topicwhotime irc_rpl_notopic
/;

has _irc => sub {
  my $self = shift;
  my $irc  = Mojo::IRC->new;

  Scalar::Util::weaken($self);
  $irc->register_default_event_handlers;
  $irc->on(
    close => sub {
      my $irc = shift;
      $self->_publish(wirc_notice => { message => "Disconnected from @{[$irc->server]}. Attempting reconnect in @{[$self->_reconnect_in]} seconds." });
      $irc->ioloop->timer($self->_reconnect_in, sub { $self->_connect });
    }
  );

  for my $event (@ADD_MESSAGE_EVENTS) {
    $irc->on($event => sub { $self->add_message($_[1]) });
  }
  for my $event (@ADD_SERVER_MESSAGE_EVENTS) {
    $irc->on($event => sub { $self->add_server_message($_[1]) });
  }
  for my $event (@OTHER_EVENTS) {
    $irc->on($event => sub { $self->$event($_[1]) });
  }

  $irc;
};

has _reconnect_in => 10;

=head1 METHODS

=head2 connect

  $self = $self->connect;

This method will create a new L<Mojo::IRC> object with attribute data from
L</redis>. The values fetched from the backend is identified by L</id>. This
method then call L<Mojo::IRC/connect> after the object is set up.

Attributes fetched from backend: nick, user, host and channels. The latter
is set in L</channels> and used by L</irc_rpl_welcome>.

=cut

sub connect {
  my ($self) = @_;
  my $irc = $self->_irc;
  my $id = $self->id or croak "Cannot load connection without id";

  # we will try to "steal" the nich we want every 60 second
  $self->{keepnick_tid} ||= $irc->ioloop->recurring(60, sub {
    $self->redis->hget("connection:$id", "nick", sub { $irc->change_nick($_[1]) });
  });

  $self->_connect;
  $self->_subscribe;
  $self;
}

sub _subscribe {
  my $self = shift;
  my $id = $self->id;
  my $irc = $self->_irc;

  Scalar::Util::weaken($self);
  $self->{messages} = $self->redis->subscribe("connection:$id:to_server");
  $self->{messages}->timeout(0);
  $self->{messages}->on(
    error => sub {
      my ($sub, $error) = @_;
      $self->log->warn("[$id] Re-subcribing to messages to @{[$irc->server]}. ($error)");
      $self->_subscribe;
    },
  );
  $self->{messages}->on(
    message => sub {
      my ($sub, $raw_message) = @_;
      my $message = Parse::IRC::parse_irc(sprintf ':%s %s', $irc->nick, $raw_message);

      unless(ref $message) {
        $self->_publish(wirc_notice => { message => "Unable to parse: $raw_message" });
        return;
      }

      $irc->write($raw_message, sub {
        my($irc, $error) = @_;

        if($error) {
          $self->_publish(wirc_notice => { message => "Could not send message to @{[$irc->server]}: $error" });
        }
        elsif($message->{command} eq 'PRIVMSG') {
          $self->add_message($message);
        }
        else {
          my $action = 'cmd_' . lc $message->{command};
          $self->$action($message) if $self->can($action);
        }
      });
    }
  );

  $self;
}

sub _connect {
  my $self = shift;
  my $id = $self->id;
  my $irc = $self->_irc;

  Scalar::Util::weaken($self);

  $self->redis->execute(
    [hgetall  => "connection:$id"],
    [smembers => "connection:$id:channels"],
    sub {
      my ($redis, $attrs, $channels) = @_;

      $self->channels($channels);
      $irc->server($attrs->{host});
      $irc->nick($attrs->{nick});
      $irc->user($attrs->{user});
      $irc->connect(sub {
        my($irc, $error) = @_;

        if($error) {
          $self->_publish(wirc_notice => { message => "Could not connect to @{[$irc->server]}: $error" });
          $irc->ioloop->timer($self->_reconnect_in, sub { $self->_connect });
        }
        else {
          $self->redis->hset("connection:@{[$self->id]}", current_nick => $irc->nick);
          $self->_publish(wirc_notice => { message => "Connected to @{[$irc->server]}." });
        }
      });
    },
  );
}

=head2 add_server_message

  $self->add_server_message(\%message);

Will look at L<%message> and add it to the database as a server message
if it looks like one. Returns true if the message was added to redis.

=cut

sub add_server_message {
  my ($self, $message) = @_;

  if (!$message->{prefix} or $message->{prefix} eq $self->real_host) {

    # 1 = normal, 0 = error
    my $params = $message->{params};
    shift $params;
    $self->redis->incr("connection:@{[$self->id]}:unread");
    $self->_publish(
      server_message => {
        message => join(' ', @{$message->{params}}),
        save => 1,
        status => 200,
        timestamp => time,
      },
    );
  }
}

=head2 add_message

  $self->add_message(\%message);

Will add a private message to the database.

=cut

sub add_message {
  my ($self, $message) = @_;
  my $current_nick = $self->_irc->nick;
  my $msg          = $message->{params}[0] eq $current_nick;
  my $data         = {message => $message->{params}[1], save => 1};

  @{$data}{qw/nick user host/} = parse_user($message->{prefix});
  $data->{target} = lc($msg ? $data->{nick} : $message->{params}[0]);
  $data->{highlight} = ($msg or $data->{message} =~ /\b$current_nick\b/) ? 1 : 0;

  $self->_publish(
    $data->{message} =~ s/\x{1}ACTION (.*)\x{1}/$1/ ? 'action_message' : 'message',
    $data,
  );

  unless ($data->{nick} eq $current_nick) {
    $self->redis->incr("connection:@{[$self->id]}:$data->{target}:unread");
  }
  unless ($message->{params}[0] =~ /^[#&]/x) {    # not a channel or me.
    $self->redis->sadd("connection:@{[$self->id]}:conversations", $data->{target});
  }
}

=head2 disconnect

Will disconnect from the L</irc> server.

=cut

sub disconnect {
  $_[0]->_irc->disconnect($_[1] || sub { });
}

=head1 EVENT HANDLERS

=head2 irc_rpl_welcome

Example message:

:Zurich.CH.EU.Undernet.Org 001 somenick :Welcome to the UnderNet IRC Network, somenick

=cut

sub irc_rpl_welcome {
  my ($self, $message) = @_;

  $self->real_host($message->{prefix});

  for my $channel (@{$self->channels}) {
    $self->_irc->write(JOIN => $channel);
  }
}

=head2 irc_rpl_whoisuser

Reply with user info

=cut

sub irc_rpl_whoisuser {
  my ($self, $message) = @_;

  $self->_publish(
    whois => {
      nick     => $message->{params}[1],
      user     => $message->{params}[2],
      host     => $message->{params}[3],
      realname => $message->{params}[5],
    }
  );
}

=head2 irc_rpl_whoischannels

Reply with user channels

=cut

sub irc_rpl_whoischannels {
  my ($self, $message) = @_;

  $self->_publish(
    whois_channels => {
      nick => $message->{params}[1],
      channels => [sort split ' ', $message->{params}[2] || ''],
    },
  );
}

=head2 irc_rpl_notopic

  :server 331 nick #channel :No topic is set.

=cut

sub irc_rpl_notopic {
  my ($self, $message) = @_;

  $self->_publish(topic => { topic => '', target => $message->{params}[1] });
}

=head2 irc_rpl_topic

Reply with topic

=cut

sub irc_rpl_topic {
  my ($self, $message) = @_;

  $self->_publish(topic => { topic => $message->{params}[2], target => $message->{params}[1] });
}

=head2 irc_topic

    :nick!~user@hostname TOPIC #channel :some topic

=cut

sub irc_topic {
  my ($self, $message) = @_;

  $self->_publish(topic => { topic => $message->{params}[1], target => $message->{params}[0] });
}

=head2 irc_rpl_topicwhotime

Reply with who and when for topic change

=cut

sub irc_rpl_topicwhotime {
  my ($self, $message) = @_;

  $self->_publish(
    topic_by => {
      ts     => $message->{params}[3],
      nick   => $message->{params}[2],
      target => $message->{params}[1],
    }
  );
}

=head2 irc_rpl_myinfo

Example message:

:Tampa.FL.US.Undernet.org 004 somenick Tampa.FL.US.Undernet.org u2.10.12.14 dioswkgx biklmnopstvrDR bklov

=cut

sub irc_rpl_myinfo {
  my ($self, $message) = @_;
  my @keys = qw/ nick real_host version available_user_modes available_channel_modes /;
  my $i    = 0;

  $self->redis->hmset("connection:@{[$self->id]}", map { $_, $message->{params}[$i++] // '' } @keys);
}

=head2 irc_join

See L<Mojo::IRC/irc_join>.

=cut

sub irc_join {
  my ($self, $message) = @_;
  my ($nick) = IRC::Utils::parse_user($message->{prefix});
  my $channel = $message->{params}[0];

  if($nick eq $self->_irc->nick) {
    return $self->redis->del("connection:@{[$self->id]}:$channel:nicks");
  }
  $self->_publish(nick_joined => { save => 0, nick => $nick, target => $channel });
  $self->redis->sadd("connection:@{[$self->id]}:$channel:nicks", $nick);
}

=head2 irc_nick

  :old_nick!~username@1.2.3.4 NICK :new_nick

=cut

sub irc_nick {
  my ($self, $message) = @_;
  my ($old_nick) = IRC::Utils::parse_user($message->{prefix});
  my $new_nick = $message->{params}[0];

  if ($new_nick eq $self->_irc->nick) {
    $self->redis->hset("connection:@{[$self->id]}", current_nick => $new_nick);
  }

  $self->_publish(nick_change => { save => 1, old_nick => $old_nick, new_nick => $new_nick });
}

=head2 irc_part

=cut

sub irc_part {
  my ($self, $message) = @_;
  my ($nick) = IRC::Utils::parse_user($message->{prefix});
  my $channel = $message->{params}[0];

  $self->_publish(nick_parted => { nick => $nick, target => $channel, save => 0 });
  $self->redis->srem("connection:@{[$self->id]}:$channel:nicks", $nick);
}

=head2 irc_rpl_namreply

Example message:

:Budapest.Hu.Eu.Undernet.org 353 somenick = #html :somenick Indig0 Wildblue @HTML @CSS @Luch1an @Steaua_ Indig0_ Pilum @fade

=cut

sub irc_rpl_namreply {
  my ($self, $message) = @_;
  my @nicks = split /\s+/, $message->{params}[3];    # 3 = +nick0 @nick1, nick2
  my $nick = $self->_irc->nick || '';

  $self->redis->sadd(
    "connection:@{[$self->id]}:$message->{params}[2]:nicks",
    grep { $_ ne $nick } @nicks
  );
}

=head2 irc_error

Example message:

ERROR :Closing Link: somenick by Tampa.FL.US.Undernet.org (Sorry, your connection class is full - try again later or try another server)

=cut

sub irc_error {
  my ($self, $message) = @_;
  $self->add_server_message($message);
  if ($message->{raw_line} =~ /Closing Link/i) {
    $self->log->warn("[connection:@{[$self->id]}] ! Closing link (reconnect)");
  }
}

=head2 cmd_nick

Handle nick commands from user. Change nick and set new nick in redis.

=cut

sub cmd_nick {
  my ($self, $message) = @_;
  my $new_nick = $message->{params}[0];
  $self->redis->hset("connection:@{[$self->id]}", nick => $new_nick);
  $self->_irc->nick($new_nick);
}


=head2 cmd_join

Handle join commands from user. Add to channel set.

=cut

sub cmd_join {
  my ($self, $message) = @_;
  my $channel = $message->{params}[0];

  return $self->_publish(wirc_notice => { message => 'Channel to join is required' }) unless $channel;
  return $self->_publish(wirc_notice => { message => 'Channel must start with & or #' }) unless $channel =~ /^[#&]/x;
  $self->redis->sadd("connection:@{[$self->id]}:channels", $channel);

  # clean up old nick list
  $self->redis->del("connection:@{[$self->id]}:channel:$channel:nicks");
  $self->_publish(add_conversation => { target => $channel, save => 1 });
}

=head2 cmd_part

Handle part commands from user. Remove from channel set.

=cut

sub cmd_part {
  my ($self, $message) = @_;
  my $channel = $message->{params}[0];

  $self->redis->srem("connection:@{[$self->id]}:channels", $channel);
  $self->redis->del("connection:@{[$self->id]}:channel:$channel:nicks");
  $self->_publish(remove_conversation => { target => $channel, save => 1 });
}

sub _publish {
  my ($self, $event, $data) = @_;
  my $message;

  $data->{cid} //= $self->id;
  $data->{timestamp} ||= time;
  $data->{event} = $event;
  $message = $JSON->encode($data);

  $self->redis->publish("connection:$data->{cid}:from_server", $message);

  if($event eq 'wirc_notice') {
    $self->log->warn("[$data->{cid}] $data->{message}");
  }
  if($data->{save}) {
    if ($data->{target}) {
      $self->redis->zadd("connection:$data->{cid}:$data->{target}:msg", time, $message);
    }
    else {
      $self->redis->zadd("connection:$data->{cid}:msg", time, $message);
    }
  }
}

=head1 COPYRIGHT

See L<WebIrc>.

=head1 AUTHOR

Jan Henning Thorsen

Marcus Ramberg

=cut

1;
