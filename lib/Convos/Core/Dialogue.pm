package Convos::Core::Dialogue;
use Mojo::Base -base;

has active     => 0;
has frozen     => '';
has is_private => sub { Carp::confess('Not specified') };
has name       => sub { shift->id };
has password   => '';
has topic      => '';
has users      => sub { +{} };

sub connection { shift->{connection} or die 'connection required in constructor' }
sub id         { shift->{id}         or die 'id required in constructor' }
sub n_users { int keys %{$_[0]->users} || $_[0]->{n_users} || 0 }

sub messages {
  my ($self, $query, $cb) = @_;
  Scalar::Util::weaken($self);
  $self->connection->user->core->backend->messages($self, $query, sub { $self->$cb(@_[1, 2]) });
  $self;
}

sub user { shift->connection->user }

sub TO_JSON {
  my ($self, $persist) = @_;
  my %json = map { ($_, $self->$_) } qw(active frozen id name topic);
  $json{connection_id} = $self->connection->id;
  $json{users} = $self->users unless $persist;
  return \%json;
}

1;

=encoding utf8

=head1 NAME

Convos::Core::Dialogue - A convos dialogue base class

=head1 DESCRIPTION

L<Convos::Core::Dialogue> represents a dialogue (conversation) with one or
more users.

=head1 ATTRIBUTES

=head2 connection

Holds a L<Convos::Core::Connection> object.

=head2 active

  $bool = $self->active;

This is true if the user is currently active in the dialogue.

=head2 frozen

  $str = $self->frozen;

Will be set to a description if the dialogue is "frozen", which means you are
no longer part of it.

=head2 id

  $str = $self->id;

Unique identifier for this dialogue.

=head2 is_private

  $bool = $self->is_private;

Returns true if you are only talking to a single user and no other
users can join the dialogue.

=head2 name

  $str = $self->name;

The name of this dialogue.

=head2 password

  $str = $self->password;

The password used to join this dialogue.

=head2 topic

  $str = $self->topic;

The topic (subject) of the dialogue.

=head2 users

  $hash = $self->users;

Holds information about the users in this dialogue.

=head1 METHODS

=head2 messages

  $self = $self->messages(\%query, sub { my ($self, $err, $messages) = @_; });

Will fetch messages from persistent backend.

See also L<Convos::Core::Backend/messages>.

=head2 n_users

  $int = $self->n_users;

Number of users in the conversation. Zero (0) means you are not talking to
anyone.

=head2 user

  $user = $self->user;
  $user = $self->connection->user;

Shortcut for accessing the L<Convos::Core::User> object associated with this
dialogue.

=head1 AUTHOR

Jan Henning Thorsen - C<jhthorsen@cpan.org>

=cut
