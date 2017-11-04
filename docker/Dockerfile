FROM fluent/fluentd:latest
MAINTAINER tkyshm

ADD fluent.conf /fluentd/etc/fluent.conf

EXPOSE 24224
CMD fluentd -c /fluentd/etc/$FLUENTD_CONF -p /fluentd/plugins $FLUENTD_OPT
