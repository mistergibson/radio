#!/usr/bin/env jruby
Dir.chdir(File.expand_path(__dir__))
ENV["RADIO_DIR"] = File.expand_path(File.dirname(__FILE__))
exec("liquidsoap", File.expand_path("station.liq"))
