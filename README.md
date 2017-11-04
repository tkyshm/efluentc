[![Build Status](https://travis-ci.org/tkyshm/efluentc.svg?branch=master)](https://travis-ci.org/tkyshm/efluentc)

[efluentc](https://hex.pm/packages/efluentc)
=====


efluentc is the Client OTP application for Fluentd.

efluentc design is to make it more faster to send some messages which are buffered at a time, and reduce count of transmission.

If you can see performance degration that is casued by burst traffic,
I'd recommend increasing concurrency of fluent clients.

efluentc has interval to flush messages and buffer size, and you can adjust theses.
It is recommeneded that theses parameters are set appropriate value according to your application flow rate.

Available parameters below:

name          | default   | description
------------- | --------- | ----------------------------------------------------------
worker_size   | 2         | send of concurrency
flush_timeout | 50        | interval of flushing buffered data (msec)
buffer_size   | 10KB      | if over buffer size, flush all buffered data
host          | localhost | fluentd host name
port          | 24224     | fluentd port number

sample(app.config):

```erlang
[
  {efluentc, [{worker_size, 10},      % 10 workers
              {fluesh_timeout, 500},  % 500msec
              {buffer_size, 1048576}, % 1MiB
              {host, localhost},
              {port, 24224}]}
]

```

Usage
====

add rebar.config:

```
{efluentc, "0.1.0"}
```

efluentc api:
```
> efluentc:post(<<"test.tag">>, <<"message">>).
ok

> efluentc:post('test.tag', <<"message">>).
ok

> efluentc:post('test.tag', "message").
ok

> efluentc:post('test.tag', #{<<"key">> => <<"value">>}).
ok
```
