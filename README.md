Building the Kaltura HLS Plugin
===============================

To build the Kaltura HLS plugin, import the following projects into your workspace in FlashBuilder 4.6. The recommended version of the Flex SDK is 4.5.1.

   * hlsPlugin - This is the SWC.
   * KalturaHLSPlugin - This packages the SWC into a loadable OSMF SWF plugin.
   * OSMF - the version of OSMF that the plugin uses.
   * OSMFUtils - Some utilties for TestPlayer.
   * TestPlayer - A rudimentary test player provided by Digital Primates.

Set Library Path Dependencies for each of the projects:

    hlsPlugin depends on...
		OSMF project
	KalturaHLSPlugin depends on...
		hlsPlugin project
	OSMFUtils depends on...
		OSMF project
	TestPlayer depends on...
		OSMF project
		OSMFUtils project
		
Project References for each of the projects:

	hlsPlugin
		OSMF
	KalturaHLSPlugin
		hlsPlugin
		OSMF
	OSMFUtils
		OSMF
	TestPlayer
		OSMF
		OSMFUtils

Build them all to get the KalturaHLSPlugin.swf from the 
KalturaHLSPlugin/bin-debug folder. This may then be loaded in the Kaltura Player (or any OSMF-based player).

**Note:** You have to make sure that you set the project references correctly or OSMF won't be bundled with the SWF, and errors will occur due to incompatible versions.

Building With Make
==================

As an alternative to using Flash Builder, you may also use make to compile the plugins, libraries, and test player.

1. The osmf.swc file must be removed from your 4.6.0 sdk folder (in 4.6.0/frameworks/libs)
2. These lines must be changed to fit your local environment https://github.com/kaltura/HLS-OSMF/tree/master//Makefile#L6-L8, https://github.com/kaltura/HLS-OSMF/tree/master/OSMF/OSMF-build-config.xml#L69-L70, and https://github.com/kaltura/HLS-OSMF/tree/master/OSMFUtils/OSMFUtils-build-config.xml#L69-L70
3. Comment out the reference to OSMF in the flex-onfig.xml file in your 4.6.0 sdk (4.6.0/frameworks/flex-config.xml). This may require you change permission settings.
4. Run `make` in the base directory

**NOTE:** In order to run the TestPlayer visualizer, and to enable extra logging, the CONFIG::LOGGING value must be set to true here: https://github.com/kaltura/HLS-OSMF/blob/master/HLSPlugin/HLS-build-config.xml#L12

**NOTE 2:** The Makefile will only fully work on unix-like systems. If run on a DOS system, make will be unable to determine if files have been updated, and will require a manual clean before each new build. Additionally, the `make clean` command will not work. This means that for a manual clean, the built files must be deleted using the explorer.

### The Debug Visualization 

![Manifest Visualization](https://s3.amazonaws.com/uploads.hipchat.com/70076/1718358/QwaZnBtZ6wpAPMB/abc-live-throttled.png)
![Transcoder and Download Visualization](https://s3.amazonaws.com/uploads.hipchat.com/70076/961665/q1B3iAV532gFnkY/YAY.PNG)

A full featured debug visualizer is included with the HLS OSMF plugin to help with development and testing. It visualises MPEGTS->FLV transcoding, segment download activity, and manifest state and segment selection.

See TestPlayer/html-template/index.hml for details.

The visualizer is written in HTML/JS and requires the plugin to call certain methods via ExternalInterface for proper functioning. Javascript callbacks only occur if CONFIG::LOGGING is true at compile time.
Intructions follow to integrate the Debug Visualizer into your own web page.

These instructions assume you are starting from the [index.template.html](https://github.com/kaltura/HLS-OSMF/blob/master/TestPlayer/html-template/index.template.html). Extrapolate these insstructions as required.

1. Build the TestPlayer.swf. See "Building with Make" for instructions.
2. Copy the [swfobject.js](https://github.com/kaltura/HLS-OSMF/blob/master/TestPlayer/html-template/swfobject.js]), [sources.xml](https://github.com/kaltura/HLS-OSMF/blob/master/TestPlayer/html-template/sources.xml), and the generated TestPlayer.swf into the index directory.
3. Adjust the variables to fit your requirements, specifically, make sure ${swf} points to the location of the TestPlayer.swf.
4. Copy the [visualizer script](https://github.com/kaltura/HLS-OSMF/blob/BJG-BetterBitSwitching/TestPlayer/html-template/index.html#L64-L585) into your index.html.
5. Copy the [visualizer HTML Tags](https://github.com/kaltura/HLS-OSMF/blob/BJG-BetterBitSwitching/TestPlayer/html-template/index.html#L633-L636) into your index.html.

Adaptive Bitrate Selection
==========================

OSMF handles selection of video quality level dynamically based on the current network conditions. The HLS plugin manages OSMF's bitrate selection subsystem in order to give good results for HLS streaming media. This management occurs in M2TSNetLoader::createNetStreamSwitchManager(). We will discuss our modifications, then the general OSMF logic for bitrate selection.

We alter OSMF's default behavior in three general ways in M2TSNetLoader::createNetStreamSwitchManager:

   1. Only the last downloaded segment's speed is considered for determining overall speed (first two parts of the function). This helps give the fastest response to network bandwidth changes. Especially in cases where bandwidth changes a lot, even small averaging behavior will give bad results. Imagine if we cut bandwidth from 2500kbps to 250 kbps and average those two measurements at a 10%/90% ratio - you end up estimating bandwidth at 475kbps which is 2x too high!
   2. We allow switching any number of quality levels at once (third part of function, maxUpSwitchLimit and maxDownSwitchLimit). By default OSMF only switches one level at a time, which can be far too slow to avoid buffering when network bandwidth changes abruptly. It is better to jump directly to the level which is the best fit for available bandwidth.
   3. We limit the reliability record buffer to length 3 (third part of function, maxReliabilityRecordSize). Normally it is 30 records long. "Reliability" is a metric calculated by OSMF which takes into account situations where we end up buffering. If a quality level experiences buffering events, then the reliability is reduced, and it will tend not to be selected as long as the reliability record "remembers" the buffering event. The reliability record buffer contains one record per segment played - so in a nominal 10 second segment length stream, the memory is 5 minutes long. In our tests, this is far too long; 3 records gives 30 seconds of memory which is sufficient for most situations and doesn't force users into low quality playback situations for extended periods.

How does OSMF work to select bitrates generally? 

We use the DefaultHTTPStreamingSwitchManager, which is the bitrate selection implementation tailored for HTTP based streaming video. The DHSSM (DefaultHTTPStreamingSwitchManager) manages a repository of metrics - observations about current and historical playback performance - and rules - conditions which are evaluated based on the available metrics and which may recommend a new target bitrate. Every time a segment has completed downloading, an HTTPStreamingEvent.RUN_ALGORITHM event is fired which triggers the DHSSM to update metrics, recalculate rule recommendations, and choose the "best" recommendation as the next target quality level.

The metrics are contained in the org.osmf.net.metrics package. They measure information like the average FPS, buffer occupancy, available quality levels, and so on. They return a MetricValue containing a reference to their computed value when they are updated.

The rules are contained in the org.osmf.net.rules package. They respond to various aspects of the playback system - available buffer length, if dropped frames have been occuring, current bandwidth, etc. Rules return a Recommendation object encoding the best action to take in the current situation (according to that rule) and a scalar indicating the strength of the recommendation.
