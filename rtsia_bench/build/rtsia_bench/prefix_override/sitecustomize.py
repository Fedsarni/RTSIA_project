import sys
if sys.prefix == '/usr':
    sys.real_prefix = sys.prefix
    sys.prefix = sys.exec_prefix = '/home/orinagx/RTSIASarnataroTafuri/rtsia_bench/install/rtsia_bench'
