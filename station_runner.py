import os, subprocess, sys
install_dir = os.path.dirname(os.path.abspath(__file__))
os.chdir(install_dir)
sys.exit(subprocess.call(["liquidsoap", os.path.join(install_dir, "station.liq")]))
