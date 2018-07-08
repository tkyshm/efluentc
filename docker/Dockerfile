FROM fluent/fluentd:v1.2.2
MAINTAINER tkyshm

ADD fluent.conf /fluentd/etc/fluent.conf

EXPOSE 24224
CMD fluentd -c /fluentd/etc/$FLUENTD_CONF -p /fluentd/plugins $FLUENTD_OPT
