all: 
	~/Downloads/SnowLeopard_Lion_Mountain_Lion_Mavericks_19.01.2015/ffprobe -show_packets -show_frames -bitexact -private -select_streams a media-uot1gpjgc_b882432_DVR_74.ts > out.log 2> out.err
	rm -f M2TSTest.abc
	REDTAMARIN_SDK=/Users/bengarney/Downloads/redtamarin-sdk-macintosh ~/Downloads/redtamarin-sdk-macintosh/bin/redbean

dummy:	
	~/Downloads/SnowLeopard_Lion_Mountain_Lion_Mavericks_19.01.2015/ffprobe -show_packets -show_frames -bitexact -private -select_streams v seg-15-v1-a1.ts > seg-15-v1-a1.ts.log 2> seg-15-v1-a1.ts.log.err
	-diff -d seg-15-v1-a1.ts.flv.log seg-15-v1-a1.ts.log > diff_ts_ffprobe.log
	terminal-notifier -message "Complete" -title "Tamarin Parser"

%.ts.flv.log: %.ts.flv
	echo Creating dump $@
	~/Downloads/SnowLeopard_Lion_Mountain_Lion_Mavericks_19.01.2015/ffprobe -show_packets -show_frames -bitexact -private -select_streams v $< > $@ 2> $@.err
	-flvmeta -C $< > $<.flvmetacheck.log
	flvmeta -F $< > $<.flvmeta.log

%.ts.flv: %.ts
	rm -f M2TSTest.abc $<
	REDTAMARIN_SDK=/Users/bengarney/Downloads/redtamarin-sdk-macintosh ~/Downloads/redtamarin-sdk-macintosh/bin/redbean