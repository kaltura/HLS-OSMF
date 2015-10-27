A standalone version of the MPEG2 TS -> FLV transcoder which can be used for testing/debugging.

This requires:
   * RedTamarin http://redtamarin.com/
   * ffmpeg binaries http://ffmpeg.org/
   * Make (hopefully already on your system!) - the makefile is a bit of a mess.

M2TSTest.as contains the parser implementation extracted and slightly modified from the HLS-OSMF plugin plus a small testing harness.

To build and run, run redbean from RedTamarin. The inputs/outputs are currently hardcoded.