#!/usr/bin/env sh

exec env DBUS_VERBOSE=1 /app/build/bus/dbus-daemon \
  --config-file=session.conf \
  --print-address
