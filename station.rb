Dir.chdir(File.expand_path(__dir__))
exec("liquidsoap", File.expand_path("station.liq"))
