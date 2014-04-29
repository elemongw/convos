# nordaaker/convos
#
# BUILD: docker build --no-cache --rm -t nordaaker/convos .
# RUN:   docker run -p $PORT:8080 nordaaker/convos

FROM stackbrew/ubuntu:13.10

RUN apt-get update && apt-get install -y \
    software-properties-common \
    curl \
    perl \
    make \
    rubygems \
    libio-socket-ssl-perl \
    supervisor \
    redis-server

ADD ./vendor/supervisord.conf /etc/supervisor/conf.d/supervisord.conf
ADD . /convos
RUN gem install sass
RUN cd /convos; ./vendor/bin/carton

ENV MOJO_MODE production
ENV CONVOS_REDIS_URL redis://127.0.0.1:6379/1
ENV CONVOS_INVITE_CODE convos

EXPOSE 8080
ENTRYPOINT ["/usr/bin/supervisord"]
