package com.kaltura.hls
{
	import com.kaltura.hls.m2ts.IExtraIndexHandlerState;
	import com.kaltura.hls.m2ts.M2TSFileHandler;
	import com.kaltura.hls.manifest.HLSManifestEncryptionKey;
	import com.kaltura.hls.manifest.HLSManifestParser;
	import com.kaltura.hls.manifest.HLSManifestSegment;
	import com.kaltura.hls.manifest.HLSManifestStream;
	
	import flash.events.Event;
	import flash.events.EventDispatcher;
	import flash.events.IEventDispatcher;
	import flash.events.IOErrorEvent;
	import flash.events.TimerEvent;
	import flash.utils.Timer;
	import flash.utils.ByteArray;
	import flash.utils.getTimer;
	import flash.utils.IDataInput;
	
	import org.osmf.events.DVRStreamInfoEvent;
	import org.osmf.events.HTTPStreamingEvent;
	import org.osmf.events.HTTPStreamingIndexHandlerEvent;
	import org.osmf.events.HTTPStreamingEventReason;
	import org.osmf.media.MediaResourceBase;
	import org.osmf.net.DynamicStreamingItem;
	import org.osmf.net.httpstreaming.HLSHTTPNetStream;
	import org.osmf.net.httpstreaming.HTTPStreamDownloader;
	import org.osmf.net.httpstreaming.HTTPStreamRequest;
	import org.osmf.net.httpstreaming.HTTPStreamRequestKind;
	import org.osmf.net.httpstreaming.HTTPStreamingFileHandlerBase;
	import org.osmf.net.httpstreaming.HTTPStreamingIndexHandlerBase;
	import org.osmf.net.httpstreaming.dvr.DVRInfo;
	import org.osmf.net.httpstreaming.flv.FLVTagScriptDataMode;
	import org.osmf.net.httpstreaming.flv.FLVTagScriptDataObject;

	import org.osmf.logging.Logger;
	import org.osmf.logging.Log;
	
	public class HLSIndexHandler extends HTTPStreamingIndexHandlerBase implements IExtraIndexHandlerState
	{
		// Time in seconds to wait before retrying a LIVE_STALL
		public static const RETRY_INTERVAL:uint = 3;
		
		// Set when we rewrote the current seek target.
		public var bumpedTime:Boolean = false;
		// The new current seek target.
		public var bumpedSeek:Number = 0;

		public var _lastSequence:int = 0;
		public var _lastSequenceManifest:HLSManifestParser = null;

		public function updateLastSequence(newManifest:HLSManifestParser, newSeq:int):void
		{
			trace("UPDATING LAST SEQUENCE " + newSeq + " manifest=" + newManifest.fullUrl);
			_lastSequence = newSeq;
			_lastSequenceManifest = newManifest;
		}

		public function getLastSequence():int
		{
			return _lastSequence;
		}

		public function getLastSequenceManifest():HLSManifestParser
		{
			return _lastSequenceManifest;
		}

		public function getLastSequenceSegments():Vector.<HLSManifestSegment>
		{
			if(_lastSequenceManifest)
				return _lastSequenceManifest.segments;
			return new Vector.<HLSManifestSegment>();
		}

		public var lastKnownPlaylistStartTime:Number = 0.0;
		public var lastQuality:int = 0;
		public var targetQuality:int = 0;
		public var manifest:HLSManifestParser = null;
		public var reloadingManifest:HLSManifestParser = null;
		public var reloadingQuality:int = 0;
		public var baseUrl:String = null;
		public var resource:HLSStreamingResource;
		
		private var reloadTimer:Timer = null;
		private var sequenceSkips:int = 0;
		private var stalled:Boolean = false;
		private var fileHandler:M2TSFileHandler;
		private var backupStreamNumber:int = 0;// Which backup stream we are currently on. Used to effectively switch between backup streams
		private var primaryStream:HLSManifestStream;// The manifest we are currently using when we attempt to switch to a backup
		private var isRecovering:Boolean = false;// If we are currently recovering from a URL error
		private var lastBadManifestUri:String = "Unknown URI";
		
		// _bestEffortState values
		private static const BEST_EFFORT_STATE_OFF:String = "off"; 											// not performing best effort fetch
		private static const BEST_EFFORT_STATE_PLAY:String = "play"; 										// doing best effort for liveness or dropout
		private static const BEST_EFFORT_STATE_SEEK_BACKWARD:String = "seekBackward";						// in the backward fetch phase of best effort seek
		private static const BEST_EFFORT_STATE_SEEK_FORWARD:String = "seekForward";							// in the forward fetch phase of best effort seek
		
		private var _bestEffortInited:Boolean = false;														// did we initialize _bestEffortEnabled?
		private var _bestEffortEnabled:Boolean = false;														// is BEF enabled at all?
		private var _bestEffortState:String =  BEST_EFFORT_STATE_OFF;										// the current state of best effort
		private var _bestEffortSeekTime:Number = 0;															// the time we're seeking to
		private var _bestEffortDownloaderMonitor:EventDispatcher = null; 									// Special dispatcher to handler the results of best-effort downloads.
		private var _bestEffortFailedFetches:uint = 0; 														// The number of fetches that have failed so far.
		private var _bestEffortDownloadReply:String = null;													// After initiating a download, this is the DOWNLOAD_CONTINUE or DOWNLOAD_SKIP reply that we sent
		private var _bestEffortFileHandler:M2TSFileHandler = new M2TSFileHandler();							// used to pre-parse backward seeks
		private var _bestEffortSeekBuffer:ByteArray = new ByteArray();										// buffer for saving bytes when pre-parsing backward seek
		private var _bestEffortLastGoodFragmentDownloadTime:Date = null;
		
		private var _pendingBestEffortRequest:HTTPStreamRequest = null;

		private var _pendingBestEffortStartTime:int = -1;

		private function isBestEffortActive():Boolean
		{
			var dt:int = getTimer() - _pendingBestEffortStartTime;
			if(dt > 30*1000) // Timeout on best effort requests of 30 seconds.
				return false;
			if(_bestEffortDownloaderMonitor != null)
				return true;
			if(_pendingBestEffortRequest != null)
				return true;
			return false;
		}

		// constants used by getNextRequestForBestEffortPlay:
		private static const BEST_EFFORT_PLAY_SITUAUTION_NORMAL:String = "normal";
		private static const BEST_EFFORT_PLAY_SITUAUTION_DROPOUT:String = "dropout";
		private static const BEST_EFFORT_PLAY_SITUAUTION_LIVENESS:String = "liveness";
		private static const BEST_EFFORT_PLAY_SITUAUTION_DONE:String = "done";

		// We keep a list of witnesses of known PTS start values for segments.
		// This is indexed by segment URL and returns the PTS start for that
		// seg if known.  Since all segments are immutable, we can keep this
		// as a global cache.
		public static var startTimeWitnesses:Object = {};


		CONFIG::LOGGING
		{
			private static const logger:Logger = Log.getLogger("org.osmf.net.httpstreaming.HTTPNetStream");
			private var previouslyLoggedState:String = null;
		}

		public function HLSIndexHandler(_resource:MediaResourceBase, _fileHandler:HTTPStreamingFileHandlerBase)
		{
			resource = _resource as HLSStreamingResource;
			manifest = resource.manifest;
			baseUrl = manifest.baseUrl;
			fileHandler = _fileHandler as M2TSFileHandler;
			fileHandler.extendedIndexHandler = this;

			_bestEffortFileHandler.addEventListener(HTTPStreamingEvent.FRAGMENT_DURATION, onBestEffortParsed);
			_bestEffortFileHandler.isBestEffort = true;
		}


		public function updateSegmentTimes(segments:Vector.<HLSManifestSegment>):Vector.<HLSManifestSegment>
		{
			// Using our witnesses, fill in as much knowledge as we can about 
			// segment start/end times.

			// Keep track of whatever segments we've assigned to.
			var setSegments:Object = {};

			// First, set any exactly known values.
			for(var i:int=0; i<segments.length; i++)
			{
				// Skip unknowns.
				if(!startTimeWitnesses.hasOwnProperty(segments[i].uri))
					continue;

				segments[i].startTime = startTimeWitnesses[segments[i].uri];
				setSegments[i] = 1;
			}

			if(segments.length > 1)
			{
				// Then fill in any unknowns scanning forward....
				for(i=1; i<segments.length; i++)
				{
					// Skip unknowns.
					if(!setSegments.hasOwnProperty(i-1))
						continue;

					segments[i].startTime = segments[i-1].startTime + segments[i-1].duration;
					setSegments[i] = 1;
				}

				// And scanning back...
				for(i=segments.length-2; i>=0; i--)
				{
					// Skip unknowns.
					if(!setSegments.hasOwnProperty(i+1))
						continue;

					segments[i].startTime = segments[i+1].startTime - segments[i].duration;
					setSegments[i] = 1;
				}
			}

			// Dump results:
			/*trace("Last 10 manifest time reconstruction");
			for(i=Math.max(0, segments.length - 100); i<segments.length; i++)
			{
				trace("segment #" + i + " start=" + segments[i].startTime + " duration=" + segments[i].duration + " uri=" + segments[i].uri);
			}*/
			trace("Reconstructed manifest time with knowledge=" + checkAnySegmentKnowledge(segments) + " firstTime=" + (segments.length > 1 ? segments[0].startTime : -1) + " lastTime=" + (segments.length > 1 ? segments[segments.length-1].startTime : -1));

			// Done!
			return segments;
		}

		/**
		 * Return true if we have encountered any segments from this list of segments. Useful for
		 * determining if we need to do a best effort based seek and/or if the estimates are any good.
		 */
		public static function checkAnySegmentKnowledge(segments:Vector.<HLSManifestSegment>):Boolean
		{
			// Find matches.
			for(var i:int=0; i<segments.length; i++)
			{
				// Skip unknowns.
				if(startTimeWitnesses.hasOwnProperty(segments[i].uri))
					return true;
			}

			return false;
		}

		public static function getSegmentBySequence(segments:Vector.<HLSManifestSegment>, id:int):HLSManifestSegment
		{
			// Find matches.
			for(var i:int=0; i<segments.length; i++)
			{
				const seg:HLSManifestSegment = segments[i];
				if(seg.id != id)
					continue;
				return seg;
			}

			return null;
		}

		public static function getSegmentStartTimeBySequence(segments:Vector.<HLSManifestSegment>, id:int):Number
		{
			// Find matches.
			for(var i:int=0; i<segments.length; i++)
			{
				var seg:HLSManifestSegment = segments[i];
				if(seg.id == id)
					return seg.startTime;
			}

			return -1;
		}

		public static function getSegmentContainingTime(segments:Vector.<HLSManifestSegment>, time:Number, biasBackward:Boolean = false):HLSManifestSegment
		{
			if(biasBackward)
			{			
				// Find matches.
				for(var i:int=0; i<segments.length; i++)
				{
					var seg:HLSManifestSegment = segments[i];
					if(seg.startTime <= time && time < (seg.startTime + seg.duration))
						return seg;
				}
			}
			else
			{
				// Find matches.
				for(var i:int=0; i<segments.length; i++)
				{
					var seg:HLSManifestSegment = segments[i];
					if(seg.startTime <= time && time <= (seg.startTime + seg.duration))
						return seg;
				}				
			}

			// No match, dump to aid debug.
			if(segments.length <= 10)
			{
				for(i=0; i<segments.length-1; i++)
				{
					seg = segments[i];
					trace("#" + i + " id=" + seg.id + " start=" + seg.startTime + " end=" + (seg.startTime + seg.duration));
				}
			}
			else
			{
				// First 3
				for(i=0; i<3; i++)
				{
					seg = segments[i];
					trace("#" + i + " id=" + seg.id + " start=" + seg.startTime + " end=" + (seg.startTime + seg.duration));
				}

				trace(" .... skipping middle ....");

				// Last 3
				for(i=segments.length-4; i<segments.length-1; i++)
				{
					seg = segments[i];
					trace("#" + i + " id=" + seg.id + " start=" + seg.startTime + " end=" + (seg.startTime + seg.duration));
				}
			}

			return null;
		}

		/**
		 * Get the index of the segment containing a certain time.
		 */
		public static function getSegmentSequenceContainingTime(segments:Vector.<HLSManifestSegment>, time:Number):int
		{
			var seg:HLSManifestSegment = getSegmentContainingTime(segments, time);
			if(!seg)
				return -1;
			return seg.id;
		}

		public override function initialize(indexInfo:Object):void
		{
			postRatesReady();
			postIndexReady();
			updateTotalDuration();
			
			var man:HLSManifestParser = getManifestForQuality(lastQuality);
			if (man && !man.streamEnds && man.segments.length > 0)
			{
				if (!reloadTimer)
					setUpReloadTimer(man.segments[man.segments.length-1].duration * 1000);
			}
			
			// Reset our recovery variables just in case
			isRecovering = false;
			backupStreamNumber = 0;
		}
		
		private function setUpReloadTimer(initialDelay:int):void
		{
			reloadTimer = new Timer(initialDelay);
			reloadTimer.addEventListener(TimerEvent.TIMER, onReloadTimer);
			reloadTimer.start();
		}
		
		private function onReloadTimer(event:TimerEvent):void
		{
			if (isRecovering)
			{
				attemptRecovery();
				reloadTimer.reset();
			}
			else if (targetQuality != lastQuality)
				reload(targetQuality);
			else
				reload(lastQuality);
		}
		
		// Here a quality of -1 indicates that we are attempting to load a backup manifest
		public function reload(quality:int, manifest:HLSManifestParser = null):void
		{
			if (reloadTimer)
				reloadTimer.stop(); // In case the timer is active - don't want to do another reload in the middle of it

			trace("Scheduling reload for quality " + quality);
			reloadingQuality = quality;

			// Make sure we have knowledge of our current stream.
			if(!checkAnySegmentKnowledge(getManifestForQuality(lastQuality).segments) 
				&& !isBestEffortActive())
				_pendingBestEffortRequest = initiateBestEffortRequest(uint.MAX_VALUE, lastQuality);

			// Reload the manifest we were given, if we were given a manifest
			var manToReload:HLSManifestParser = manifest ? manifest : getManifestForQuality(reloadingQuality);
			reloadingManifest = new HLSManifestParser();
			reloadingManifest.type = manToReload.type;
			reloadingManifest.addEventListener(Event.COMPLETE, onReloadComplete);
			reloadingManifest.addEventListener(IOErrorEvent.IO_ERROR, onReloadError);
			reloadingManifest.reload(manToReload);
		}
		
		private function onReloadError(event:Event):void
		{
			isRecovering = true;
			lastBadManifestUri = (event as IOErrorEvent).text;
			
			// Create our timer if it hasn't been created yet and set the delay to our delay time
			if (!reloadTimer)
				setUpReloadTimer(HLSHTTPNetStream.reloadDelayTime);
			else if (reloadTimer.delay != HLSHTTPNetStream.reloadDelayTime)
			{
				reloadTimer.reset();
				reloadTimer.delay = HLSHTTPNetStream.reloadDelayTime;
			}
			
			reloadTimer.start();
			
			if (reloadTimer.currentCount < 1)
			{
				return;
			}
			
			attemptRecovery();
		}
		
		private function attemptRecovery():void
		{
			isRecovering = false;
			
			if (!HLSHTTPNetStream.errorSurrenderTimer.running)
				HLSHTTPNetStream.errorSurrenderTimer.start();
			
			// Shut everything down if we have had too many errors in a row
			if (HLSHTTPNetStream.errorSurrenderTimer.currentCount >= HLSHTTPNetStream.recognizeBadStreamTime)
			{
				HLSHTTPNetStream.badManifestUrl = lastBadManifestUri;
				return;	
			}
			
			// This might just be a bad manifest, so try swapping it with a backup if we can and reload the manifest immediately
			var quality:int = targetQuality != lastQuality ? targetQuality : lastQuality;
			backupStreamNumber = backupStreamNumber >= manifest.streams.length - 1 ? 0 : backupStreamNumber + 1;
			
			if (!swapBackupStream(quality, targetQuality != lastQuality, backupStreamNumber))
			{
				trace("Simply reloading new quality: " + targetQuality + " (old=" + lastQuality + ")");
				reload(quality);
			}
		}
		
		/**
		 * Swaps a requested stream with its backup if it is available. If no backup is available, or the requested stream cannot be found
		 * then nothing will be done. Can accept either an integer representing a quality level or an HLSManifestStream object representing a
		 * reference to the requested stream.
		 * 
		 * @param stream Value used to find a stream to replace with its backup. If an int is provided it will find a stream of the requested
		 * quality level. If an HLSManifestStream object is provided it will find the stream referenced by the object. No other data types are
		 * accepted.
		 * @param backupOffset The number of the backup to be used relative to the requested stream.
		 * 
		 * @returns Returns whether or not a backup could be found for the requested stream
		 */
		private function swapBackupStream(stream:*, forceQualityChange:Boolean, backupOffset:int = 0):Boolean
		{
			// If the requested stream has a backup, switch to it
			if (stream is int)
			{
				// If we were given an int then switch a stream with its backup at the requested quality level
				if (stream >= 0 && manifest.streams.length > stream && manifest.streams[stream].backupStream)
				{
					primaryStream = manifest.streams[stream];
					var streamToReload:HLSManifestStream = manifest.streams[stream].backupStream;
					for (var i:int = 0; i < backupOffset; i++)
					{
						streamToReload = streamToReload.backupStream;
					}
					reload(-1, streamToReload.manifest);
				}
				else
				{
					trace("Backup Stream Swap Failed: No backup stream of quality level " + stream + " found. Max quality level is " + (manifest.streams.length - 1));
					return false;
				}
			}
			else if (stream is HLSManifestStream)
			{
				// If we were given an HLSManifestStream object, find that stream in our master list and switch to the backup if possible
				for (i = 0; i <= manifest.streams.length; i++)
				{
					if (i == manifest.streams.length)
					{
						trace("Backup Stream Swap Failed: No stream with URI " + (stream as HLSManifestStream).uri + " with a backup found");
						return false;
					}
					
					if (manifest.streams[i] == stream && manifest.streams[i].backupStream)
					{
						primaryStream = manifest.streams[i];
						reload(-1, manifest.streams[i].backupStream.manifest);
						return true;
					}
				}
			}
			else
			{
				throw new Error("Function swapBackupStream() in HLSIndexHandler given invalid parameter. Parameter data: " + stream);
				return false;
			}
			
			return true;
		}

		/**
		 * Attempt to remap a sequence from an old manifest to a new.
		 *
		 * Will fire timebase fetches.
		 *
		 * @param end If true, we remap based on end time of cur segment, else on start time.
		 *
		 * Returns -1 if it can't fulfill request right now.
		 */
		private function remapSequence(currentManifest:HLSManifestParser, newManifest:HLSManifestParser, currentSequence:int, end:Boolean = true):int
		{
			if(currentManifest == null)
			{
				trace("remapSequence - no currentManifest!")
				return -1;
			}

			if(newManifest == null)
			{
				trace("remapSequence - no newManifest!");
				return -1;
			}

			if(currentManifest == newManifest)
			{
				return currentSequence;
			}

			var newSequence:int = -1;

			// Check knowledge on both sequences and queue request as appropriate.
			if(!checkAnySegmentKnowledge(newManifest.segments) && !isBestEffortActive())
			{
				trace("(A) Encountered a live/VOD manifest with no timebase knowledge, request newest segment via best effort path for quality " + reloadingQuality);
				_pendingBestEffortRequest = initiateBestEffortRequest(newManifest.streamEnds ? 0 : uint.MAX_VALUE, reloadingQuality, newManifest.segments);
			} 
			else if(!checkAnySegmentKnowledge(currentManifest.segments) && !isBestEffortActive())
			{
				trace("(B) Encountered a live/VOD manifest with no timebase knowledge, request newest segment via best effort path for quality " + reloadingQuality);
				_pendingBestEffortRequest = initiateBestEffortRequest(currentManifest.streamEnds ? 0 : uint.MAX_VALUE, lastQuality);
			}

			if(!checkAnySegmentKnowledge(newManifest.segments) || !checkAnySegmentKnowledge(currentManifest.segments))
			{
				trace("Bailing on reload due to lack of knowledge!");
				
				// re-reload.
				reloadingManifest = null; // don't want to hang on to this one.
				if (reloadTimer) reloadTimer.start();

				return -1;
			}

			// Remap time!
			updateSegmentTimes(currentManifest.segments);
			updateSegmentTimes(newManifest.segments);

			const fudgeTime:Number = 1.0;
			var currentSeg:HLSManifestSegment = getSegmentBySequence(currentManifest.segments, currentSequence);
			var newSeg:HLSManifestSegment = currentSeg ? getSegmentContainingTime(newManifest.segments, currentSeg.startTime + (end ? currentSeg.duration : 0), !end) : null;
			if(newSeg == null)
			{
				trace("Remapping from " + currentSequence);

				if(currentSeg)
				{
					// Guess by time....
					trace("Found last seg with startTime = " + currentSeg.startTime + " duration=" + currentSeg.duration);

					// If the segment is beyond last ID, then jump to end...
					if(currentSeg.startTime + currentSeg.duration >= newManifest.segments[newManifest.segments.length-1].startTime)
					{
						trace("ERROR: Couldn't remap sequence to new quality level, restarting at last time " + newManifest.segments[newManifest.segments.length-1].startTime);
						newSequence = newManifest.segments[newManifest.segments.length-1].id;
					}
					else
					{
						trace("ERROR: Couldn't remap sequence to new quality level, restarting at first time " + newManifest.segments[0].startTime);
						newSequence = newManifest.segments[0].id;
					}
				}
				else
				{
					// Guess by sequence number...
					trace("No last seg found");

					// If the segment is beyond last ID, then jump to end...
					if(currentSequence >= newManifest.segments[newManifest.segments.length-1].id)
					{
						trace("ERROR: Couldn't remap sequence to new quality level, restarting at last sequence " + newManifest.segments[newManifest.segments.length-1].id);
						newSequence = newManifest.segments[newManifest.segments.length-1].id;
					}
					else
					{
						trace("ERROR: Couldn't remap sequence to new quality level, restarting at first sequence " + newManifest.segments[0].id);
						newSequence = newManifest.segments[0].id;
					}
				}
			}
			else
			{
				trace("Currently on #" + currentSequence + " start=" + currentSeg.startTime + " end=" + (currentSeg.startTime + currentSeg.duration));
				newSequence = newSeg.id;
				trace("===== Remapping to #" + newSequence + " start=" + newSeg.startTime + " end=" + (newSeg.startTime + newSeg.duration) );
			}

			// And note how we ended.
			trace("   o Ended at " + newSequence);
			return newSequence;
		}

		private function onReloadComplete(event:Event):void
		{
			trace ("::onReloadComplete - last/reload/target: " + lastQuality + "/" + reloadingQuality + "/" + targetQuality);
			var newManifest:HLSManifestParser = event.target as HLSManifestParser;

			if(!newManifest)
			{
				trace("::onReloadComplete - failed to get new manifest?!");

				// Same as at end of function.
				dispatchDVRStreamInfo();
				reloadingManifest = null; // don't want to hang on to it
				if (reloadTimer) reloadTimer.start();
				return;
			}

			// Detect if there are 0 segments in the new manifest
			if (newManifest.segments.length == 0)
			{
				trace("WARNING: newManifest has 0 segments");
				return;
			}
			
			// Set the timer delay to the most likely possible delay
			if (reloadTimer && newManifest.segments.length > 0)
			{
				reloadTimer.delay = newManifest.segments[newManifest.segments.length - 1].duration * 1000;
			}
			
			// remove the reload completed listener since this might become the new manifest
			newManifest.removeEventListener(Event.COMPLETE, onReloadComplete);
			
			// Handle backup source swaps.
			if (reloadingQuality == -1)
			{
				// Find the stream to replace with its backup
				for (var i:int = 0; i <= manifest.streams.length; i++)
				{
					if (i == manifest.streams.length)
					{
						trace ("WARNING - Backup Replacement Failed: Stream with URI " + primaryStream.uri + " not found");
						break;
					}
					
					if (manifest.streams[i] == primaryStream && manifest.streams[i].backupStream)
					{
						reloadingQuality = i;
						manifest.streams[i] = manifest.streams[i].backupStream;
						HLSHTTPNetStream.currentStream = manifest.streams[i];
						postRatesReady();
						break;
					}
				}				
			}

			var currentManifest:HLSManifestParser = getManifestForQuality(lastQuality);
			
			var timerOnErrorDelay:Number = newManifest.targetDuration * 1000  / 2;
			
			// Remap if needed.
			var newSequence:int = remapSequence(getLastSequenceManifest(), newManifest, getLastSequence(), false);
			if(newSequence == -1)
			{
				reloadingManifest = null; // don't want to hang on to it
				if (reloadTimer) reloadTimer.start();				
				trace("Can't remap to new manifest, aborting!")
				return;
			}

			// Update our manifest for this quality level.
			trace("Setting quality to " + reloadingQuality);
			if(manifest.streams.length)
				manifest.streams[reloadingQuality].manifest = newManifest;
			else
				manifest = newManifest;
			lastQuality = reloadingQuality;

			// Update last sequence state.
			updateLastSequence(newManifest, newSequence);

			// Kick off the next round as appropriate.
			dispatchDVRStreamInfo();
			updateTotalDuration();
			reloadingManifest = null; // don't want to hang on to it
			if (reloadTimer) reloadTimer.start();

			stalled = false;
			HLSHTTPNetStream.hasGottenManifest = true;
		}

		public function getQualityLevelStreamName(index:int):String
		{
			if(!resource)
				return null;

			if(index < 0 || index > resource.streamItems.length)
				return null;

			return resource.streamItems[index].streamName;
		}
		
		public function postRatesReady():void
		{
			var streams:Array = [];
			var rates:Array = [];

			// Make a copy of the streamItems and sort them by bitrate ascending.
			var itemsCopy:Array = new Array();
			itemsCopy.length = resource.streamItems.length;
			for(var i:int=0; i<resource.streamItems.length; i++)
				itemsCopy[i] = resource.streamItems[i];
			itemsCopy.sortOn("bitrate", Array.NUMERIC)

			for(var i:int=0; i<itemsCopy.length; i++)
			{
				var curStream:DynamicStreamingItem = itemsCopy[i] as DynamicStreamingItem;
				streams.push(curStream.streamName);
				rates.push(curStream.bitrate);
			}
			
			if( resource.manifest.type == HLSManifestParser.AUDIO )
			{
				streams.push( resource.name );
				rates.push(1);
			}
			
			dispatchEvent(new HTTPStreamingIndexHandlerEvent(HTTPStreamingIndexHandlerEvent.RATES_READY, false, false, false, 
				NaN, streams, rates));			
		}
		
		public function postIndexReady():void
		{
			dispatchEvent(new HTTPStreamingIndexHandlerEvent(HTTPStreamingIndexHandlerEvent.INDEX_READY, false, false, !(getManifestForQuality(0).streamEnds) 
				/*!playlist.m_finite*/, 0 /*playlist.windowBeginOffset*/));			
		}
		
		public override function processIndexData(data:*, indexContext:Object):void
		{
			trace("processIndexData " + data + " | " + indexContext);
		}
		
		private function getWorkingQuality(requestedQuality:int):int
		{
			// Note that this method always returns lastQuality. It triggers a reload if it needs to, and
			// 	lastQuality will be set once the reload is complete.
			
			// If the requested quality is the same as what we're currently using, return that
			if (requestedQuality == lastQuality) return lastQuality;
			
			// If the requested quality is the same as the target quality, we've already asked for a reload, so return the last quality
			if (requestedQuality == targetQuality) return lastQuality;
			
			// The requested quality doesn't match eithe the targetQuality or the lastQuality, which means this is new territory.
			// So we will reload the manifest for the requested quality
			targetQuality = requestedQuality;
			trace("::getWorkingQuality Quality Change: " + lastQuality + " --> " + requestedQuality);
			reload(targetQuality);
			return lastQuality;
		}
		
		public override function getFileForTime(time:Number, quality:int):HTTPStreamRequest
		{	
			trace("getFileForTime - " + time + " quality=" + quality);
			
			var origQuality:int = quality;
			quality = getWorkingQuality(quality);

			var segments:Vector.<HLSManifestSegment> = getSegmentsForQuality( origQuality );
			if(!checkAnySegmentKnowledge(segments))
			{
				if(!isBestEffortActive())
				{
					// We may also need to establish a timebase.
					trace("getFileForTime - Seeking without timebase; initiating request.");
					return initiateBestEffortRequest(uint.MAX_VALUE, origQuality);
				}
				else 
				{
					trace("getFileForTime - Waiting on knowledge!");
					return new HTTPStreamRequest (HTTPStreamRequestKind.LIVE_STALL, null, 1);
				}
			}

			if(time < segments[0].startTime)
			{
				trace("getFileForTime - SequenceSkip - time: " + time + " playlistStartTime: " + segments[0].startTime);				
				time = segments[0].startTime;   /// TODO: HACK Alert!!! < this should likely be handled by DVRInfo (see dash plugin index handler)
												/// No longer quite so sure this is a hack, but a requirement
				++sequenceSkips;

				//bumpedTime = true;
				//bumpedSeek = time;
			}

			var seq:int = getSegmentSequenceContainingTime(segments, time);

			if(seq == -1 && segments.length >= 2)
			{
				trace("getFileForTime - Got out of bound timestamp. Trying to recover...");

				var lastSeg:HLSManifestSegment = segments[Math.max(0, segments.length - HLSManifestParser.MAX_SEG_BUFFER)];

				if(time < segments[0].startTime)
				{
					trace("getFileForTime - Fell off oldest segment, going to start #" + segments[0].id)
					seq = segments[0].id;
					//bumpedTime = true;
				}
				else if(time > lastSeg.startTime)
				{
					trace("getFileForTime - Fell off oldest segment, going to end #" + lastSeg.id)
					seq = lastSeg.id;
					//bumpedTime = true;
				}
			}

			if(seq != -1)
			{
				var curSegment:HLSManifestSegment = getSegmentBySequence(segments, seq);
				updateLastSequence(getManifestForQuality(origQuality), seq);

				fileHandler.segmentId = seq;
				fileHandler.key = getKeyForIndex( seq );
				fileHandler.segmentUri = curSegment.uri;
				trace("Getting Segment [" + seq + "] for StartTime: " + curSegment.startTime + " Continuity: " + curSegment.continuityEra + " URI: " + curSegment.uri); 
				return createHTTPStreamRequest( curSegment );
			}
			else
			{
				trace("getFileForTime - Seeking to unknown location " + time + ", waiting.");
			}
			
			// TODO: Handle live streaming lists by returning a stall.			
			if (!resource.manifest.streamEnds)
			{
				trace("getFileForTime - stalling.");
				return new HTTPStreamRequest (HTTPStreamRequestKind.LIVE_STALL, null, 1);
			}
			
			trace("getFileForTime - end of stream.s");
			return new HTTPStreamRequest(HTTPStreamRequestKind.DONE);
		}
		
		private function getSegmentForSegmentId(quality:int, segmentId:int):HLSManifestSegment
		{
			var segments:Vector.<HLSManifestSegment> = getSegmentsForQuality( quality );
			for (var i:int = 0; i < segments.length; ++i)
			{
				if (segments[i].id == segmentId)
					return segments[i];
			}
			return null;
		}
		
		public override function getNextFile(quality:int):HTTPStreamRequest
		{
			// Fire any pending best effort requests.
			if(_pendingBestEffortRequest)
			{
				trace("Firing pending best effort request: " + _pendingBestEffortRequest);
				var pber:HTTPStreamRequest = _pendingBestEffortRequest;
				_pendingBestEffortRequest = null;
				return pber;
			}

			// Report stalls and/or wait on timebase establishment.
			if (stalled)
			{
				trace("Stalling -- quality[" + quality + "] lastQuality[" + lastQuality + "]");

				// TODO - ensure a reload is pending?

				return new HTTPStreamRequest(HTTPStreamRequestKind.LIVE_STALL, null, 1);
			}

			HLSHTTPNetStream.recoveryStateNum = URLErrorRecoveryStates.NEXT_SEG_ATTEMPTED;
			
			//trace("Pre GWQ " + quality);
			var origQuality:int = quality;
			quality = getWorkingQuality(quality);

			var currentManifest:HLSManifestParser = getManifestForQuality ( origQuality );
			var oldManifest:HLSManifestParser = getLastSequenceManifest();

			if(quality != origQuality && isBestEffortActive())
			{
				trace("Waiting on best effort to resolve...");
				return new HTTPStreamRequest(HTTPStreamRequestKind.LIVE_STALL, null, 1);
			}

			// If no old manifest, it's a new play session.
			if(oldManifest == null)
			{
				trace("SEEDING LAST SEQUENCE");
				if(currentManifest.streamEnds == true)
				{
					updateLastSequence(currentManifest, 0);
				}
				else
				{
					updateLastSequence(currentManifest, currentManifest.segments[Math.max(0, currentManifest.segments.length - HLSManifestParser.MAX_SEG_BUFFER)].id);
				}
			}

			// Attempt remap.
			var newSequence:int = remapSequence(getLastSequenceManifest(), currentManifest, getLastSequence());
			if(newSequence == -1)
			{
				if(_pendingBestEffortRequest && !isBestEffortActive())
				{
					trace("Firing pending best effort request (2): " + _pendingBestEffortRequest);
					var pber:HTTPStreamRequest = _pendingBestEffortRequest;
					_pendingBestEffortRequest = null;
					return pber;
				}
				else
				{
					trace("Firing live stall");
					return new HTTPStreamRequest(HTTPStreamRequestKind.LIVE_STALL, null, 1);
				}
			}

			// Stall if we aren't ready to go.
			if(quality != origQuality && manifest.streamEnds == false)
			{
				trace("Stalling for manifest -- quality[" + quality + "] lastQuality[" + lastQuality + "]");

				// Kick the reloader.
				onReloadTimer(null);

				return new HTTPStreamRequest(HTTPStreamRequestKind.LIVE_STALL, null, 2);
			}

			// Advance sequence number.
			newSequence++;

			var segments:Vector.<HLSManifestSegment> = currentManifest.segments;

			if( segments.length > 0 && newSequence < segments[0].id)
			{
				trace("Resetting too low sequence " + newSequence + " to " + segments[0].id);
				newSequence = segments[0].id;
			}

			if (segments.length > 0 && newSequence > (segments[Math.max(0, segments.length-1)].id + 3))
			{
				trace("Got in a bad state of " + newSequence + " , resetting to near end of stream " + segments[segments.length-HLSManifestParser.MAX_SEG_BUFFER].id);
				newSequence = segments[segments.length-HLSManifestParser.MAX_SEG_BUFFER].id;
			}

			var curSegment:HLSManifestSegment = getSegmentBySequence(segments, newSequence);
			if ( curSegment != null ) 
			{
				trace("Getting Next Segment[" + newSequence + "] StartTime: " + curSegment.startTime + " Continuity: " + curSegment.continuityEra + " URI: " + curSegment.uri);
				
				// Note new value.
				updateLastSequence(currentManifest, newSequence);

				//bumpedSeek = curSegment.startTime;

				fileHandler.segmentId = newSequence;
				fileHandler.key = getKeyForIndex( newSequence );
				fileHandler.segmentUri = curSegment.uri;

				return createHTTPStreamRequest( curSegment );
			}
			
			if ( reloadingManifest || !manifest.streamEnds )
			{
				trace("Stalling -- requested segment " + newSequence + " past the end " + segments[segments.length-1].id + " and we're in a live stream");

				return new HTTPStreamRequest(HTTPStreamRequestKind.LIVE_STALL, null, segments[segments.length-1].duration / 2);
			}
			
			trace("Ending stream playback");
			return new HTTPStreamRequest(HTTPStreamRequestKind.DONE);
		}
		
		public function getKeyForIndex(index:uint):HLSManifestEncryptionKey
		{
			var keys:Vector.<HLSManifestEncryptionKey>;
			
			// Make sure we accessing returning the correct key list for the manifest type
			
			if ( manifest.type == HLSManifestParser.AUDIO ) keys = manifest.keys;
			else keys = getManifestForQuality( lastQuality ).keys;
			
			for ( var i:int = 0; i < keys.length; i++ )
			{
				var key:HLSManifestEncryptionKey = keys[ i ];
				if ( key.startSegmentId <= index && key.endSegmentId >= index )
				{
					if ( !key.isLoaded ) key.load();
					return key;
				}
			}
			
			return null;
		}
		
		/**
		 * Begins the process of switching to a backup stream if possible. Will do nothing if there is no backup stream attached
		 * to the HLSManifestStream object provided.
		 * 
		 * @param stream The stream object that we want to switch with its backup.
		 */
		public function switchToBackup(stream:HLSManifestStream):void
		{			
			// Swap the stream to its backup if possible
			if(!swapBackupStream(stream, false))
				HLSHTTPNetStream.hasGottenManifest = true;
		}
		
		private function updateTotalDuration():void
		{
			var accum:Number = NaN;
			
			if(!manifest)
				return;

			// Fetch active data.
			var activeManifest:HLSManifestParser = getManifestForQuality(lastQuality);
			var segments:Vector.<HLSManifestSegment> = activeManifest.segments;

			if(segments.length > 0)
			{
				lastKnownPlaylistStartTime = segments[0].startTime;
				var i:int = segments.length - 1;
				if (i >= 0 && (activeManifest.allowCache || activeManifest.streamEnds))
				{
					accum = (segments[i].startTime + segments[i].duration) - lastKnownPlaylistStartTime;
				}
			}

			// Push the metadata out.
			var metadata:Object = new Object();
			metadata.duration = accum;
			var tag:FLVTagScriptDataObject = new FLVTagScriptDataObject();
			tag.objects = ["onMetaData", metadata];
			dispatchEvent(new HTTPStreamingEvent(HTTPStreamingEvent.SCRIPT_DATA, false, false, 0, tag, FLVTagScriptDataMode.IMMEDIATE));
		}

		// getSegmentIndexForTime()
		//		returns
		//			-1 if there is no manifest or no valid segments
		//			the index of the first segment if the time is prior to the time of the first segment
		private function getSegmentIndexForTime(time:Number):int
		{
			return getSegmentIndexForTimeAndQuality(time, lastQuality);
		}
		
		private function getSegmentIndexForTimeAndQuality(time:Number, quality:int):int
		{
			if (!manifest)
				return -1;
			
			var segments:Vector.<HLSManifestSegment> = getSegmentsForQuality( lastQuality );

			for (var i:int = segments.length - 1; i >= 0; --i)
			{
				if (segments[i].startTime < time)
					return i;
			}
			return 0;
			
		}
		
		private function getSegmentForTime(time:Number):HLSManifestSegment
		{
			if (!manifest) 
				return null;
			
			var segments:Vector.<HLSManifestSegment> = getSegmentsForQuality( lastQuality );
			var idx:int = getSegmentIndexForTime(time);
			
			if (idx >= 0) 
				return segments[idx];
			
			return null;
		}
		
		private function dispatchDVRStreamInfo():void
		{
			var curManifest:HLSManifestParser = getManifestForQuality(lastQuality);
			var segments:Vector.<HLSManifestSegment> = curManifest.segments;
			if (segments.length == 0) 
			{
				trace("Failed to dispatch DVR info, no segments!");
				return;
			}

			updateSegmentTimes(segments);

			var firstSegment:HLSManifestSegment = segments[0];
			var lastSegment:HLSManifestSegment  = segments[segments.length - 1];

			var dvrInfo:DVRInfo = new DVRInfo();
			dvrInfo.offline = false;
			dvrInfo.isRecording = !curManifest.streamEnds;  // TODO: verify that this is what we REALLY want to be doing
			dvrInfo.startTime = firstSegment.startTime;
			dvrInfo.beginOffset = firstSegment.startTime;
			dvrInfo.endOffset = lastSegment.startTime + lastSegment.duration;
			dvrInfo.curLength = dvrInfo.endOffset - dvrInfo.beginOffset;
			dvrInfo.windowDuration = dvrInfo.curLength; // TODO: verify that this is what we want to be putting here
			
			dispatchEvent(new DVRStreamInfoEvent(DVRStreamInfoEvent.DVRSTREAMINFO, false, false, dvrInfo));
		}
		
		public override function dvrGetStreamInfo(indexInfo:Object):void
		{
			dispatchDVRStreamInfo();
		}
		
		public override function dispose():void
		{
			// We should definitely clean things up.
			if (reloadTimer != null) 
			{
				reloadTimer.stop();
				reloadTimer = null; // just to make sure
			}
		}
		
		private function getSegmentsForQuality( quality:int ):Vector.<HLSManifestSegment>
		{
			if ( !manifest ) return new Vector.<HLSManifestSegment>;
			if ( manifest.streams.length < 1 || manifest.streams[0].manifest == null )
			{
				return updateSegmentTimes(manifest.segments);
			}
			else if ( quality >= manifest.streams.length ) return updateSegmentTimes(manifest.streams[0].manifest.segments);
			else return updateSegmentTimes(manifest.streams[quality].manifest.segments);
		}
		
		private function getManifestForQuality( quality:int):HLSManifestParser
		{
			if (!manifest) return new HLSManifestParser();
			if (manifest.streams.length < 1 || manifest.streams[0].manifest == null) return manifest;
			else if ( quality >= manifest.streams.length ) return manifest.streams[0].manifest;

			// We give the HLSHTTPNetStream the stream for the quality we are currently using to help it recover after a URL error
			HLSHTTPNetStream.currentStream = manifest.streams[quality];

			// Also give HLSHTTPNetStream a reference to ourselves so it can call postRatesReady()
			HLSHTTPNetStream.indexHandler = this;

			return manifest.streams[quality].manifest;
		}
		
		private function createHTTPStreamRequest( segment:HLSManifestSegment ):HTTPStreamRequest
		{
			if ( segment == null ) return new HTTPStreamRequest(HTTPStreamRequestKind.DONE);
			trace("REQUESTING " + segment.uri);
			dispatchEvent(new HTTPStreamingEvent(HTTPStreamingEvent.FRAGMENT_DURATION, false, false, segment.duration));
			return new HTTPStreamRequest(HTTPStreamRequestKind.DOWNLOAD, segment.uri);
		}
		
		
		//-----------------------------------------------------------
		// IExtraIndexHandlerState implementation
		//
		public function getCurrentContinuityToken():String
		{
			// Check to ensure we do not get a range error
			var segments:Vector.<HLSManifestSegment> = getLastSequenceSegments();
			
			if (segments.length == 0)
			{
				var returnString:String = "/" + sequenceSkips + "/" + lastQuality + "/0";
				trace("WARNING: There are 0 segments in the last quality, generating Continuity Token \"" + returnString + "\"");
				return returnString;
			}
			
			if (getLastSequence() > segments[segments.length - 1].id || getLastSequence() < 0)
			{
				/*trace("==WARNING: lastSegmentIndex is greater than number of segments in last quality==");
				trace("lastSegmentIndex: " + getLastSequence() + " | max allowed index: " + segments[segments.length - 1].id);
				trace("Setting lastSegmentIndex to " + segments[segments.length - 1].id);
				getLastSequence() = segments[segments.length - 1].id;

				// Back off by one as it will get incremented later.
				//lastSequence--; */
			}
			
			var lastSeg:HLSManifestSegment = getSegmentBySequence(segments, getLastSequence());
			return "/" + sequenceSkips + "/" + lastQuality + "/" +  (lastSeg ? lastSeg.continuityEra : 0);
		}
		
		// returns the time offset into the fragment based on the time
		public function calculateFileOffsetForTime(time:Number):Number
		{
			var seg:HLSManifestSegment = getSegmentForTime(time);
			if (seg != null)
				return seg.startTime;
			return 0.0;
		}
		
		public function getCurrentSegmentOffset():Number
		{
			var segments:Vector.<HLSManifestSegment> = getLastSequenceSegments();
			updateSegmentTimes(segments);
			var segment:HLSManifestSegment = getSegmentBySequence( segments, getLastSequence() );
			return segment ? segment.startTime : 0.0;
		}
		
		public function getCurrentSegmentEnd():Number
		{
			var segments:Vector.<HLSManifestSegment> = getLastSequenceSegments();
			updateSegmentTimes(segments);
			var segment:HLSManifestSegment = getSegmentBySequence( segments, getLastSequence() );
			return segment ? segment.startTime + segment.duration : 0.0;
		}

		public function getTargetSegmentDuration():Number
		{
			return getManifestForQuality(lastQuality).targetDuration;
		}


		/**
		 * @private
		 * 
		 * Initiates a best effort request (from getNextFile or getFileForTime) and constructs an HTTPStreamRequest.
		 * 
		 * @return the action to take, expressed as an HTTPStreamRequest
		 **/
		private function initiateBestEffortRequest(nextFragmentId:uint, quality:int, segments:Vector.<HLSManifestSegment> = null):HTTPStreamRequest
		{
			// if we had a pending BEF download, invalidate it
			stopListeningToBestEffortDownload();
			
			// clean up best effort state
			_bestEffortDownloadReply = null;
			
			// recreate the best effort download monitor
			// this protects us against overlapping best effort downloads
			_bestEffortDownloaderMonitor = new EventDispatcher();
			_bestEffortDownloaderMonitor.addEventListener(HTTPStreamingEvent.DOWNLOAD_COMPLETE, onBestEffortDownloadComplete);
			_bestEffortDownloaderMonitor.addEventListener(HTTPStreamingEvent.DOWNLOAD_ERROR, onBestEffortDownloadError);

			if(!segments)
			{
				// Get the URL.
				var newMan:HLSManifestParser = getManifestForQuality(quality);
				if(newMan == null)
				{
					trace("initiateBestEffortRequest - No manifest found to best effort request quality level " + quality);
					return null;
				}

				segments = newMan.segments;
			}

			if(!segments)
			{
				trace("initiateBestEffortRequest - NO SEGMENTS FOUND, ABORTING initiateBestEffortRequest");
				return null;
			}

			if(nextFragmentId > segments.length - 1 || nextFragmentId == uint.MAX_VALUE)
			{
				trace("initiateBestEffortRequest - Capping to end of segment list " + (segments.length - 1));
				nextFragmentId = segments.length - 1;
			}

			_bestEffortFileHandler.segmentId = segments[nextFragmentId].id;
			_bestEffortFileHandler.key = getKeyForIndex( nextFragmentId );
			_bestEffortFileHandler.segmentUri = segments[nextFragmentId].uri;

			var streamRequest:HTTPStreamRequest =  new HTTPStreamRequest(
				HTTPStreamRequestKind.BEST_EFFORT_DOWNLOAD,
				segments[nextFragmentId].uri, // url
				-1, // retryAfter
				_bestEffortDownloaderMonitor); // bestEffortDownloaderMonitor
			
			_pendingBestEffortStartTime = getTimer();

			trace("initiateBestEffortRequest - Requesting: " + streamRequest.toString());

			return streamRequest;
		}
		
		/**
		 * @private
		 *
		 * if we had a pending BEF download, invalid it
		 **/
		private function stopListeningToBestEffortDownload():void
		{
			if(_bestEffortDownloaderMonitor != null)
			{
				trace("stopListeningToBestEffortDownload - Disconnecting existing best effort monitor.");
				_bestEffortDownloaderMonitor.removeEventListener(HTTPStreamingEvent.DOWNLOAD_COMPLETE, onBestEffortDownloadComplete);
				_bestEffortDownloaderMonitor.removeEventListener(HTTPStreamingEvent.DOWNLOAD_ERROR, onBestEffortDownloadError);
				_bestEffortDownloaderMonitor = null;
			}
		}
		
		/**
		 * @private
		 * 
		 * Best effort backward seek needs to pre-parse the fragment in order to determine if the
		 * downloaded fragment actually contains the desired seek time. This method performs that parse.
		 **/
		private function bufferAndParseDownloadedBestEffortBytes(url:String, downloader:HTTPStreamDownloader):void
		{
			if(_bestEffortDownloadReply != null)
			{
				// if we already decided to skip or continue, don't parse new bytes
				trace("bufferAndParseDownloadedBestEffortBytes - Already set our reply to " + _bestEffortDownloadReply + ", so ignoring data...");
				return;
			}

			try
			{
				var downloaderAvailableBytes:uint = downloader.totalAvailableBytes;
				trace("Saw " + downloaderAvailableBytes + " bytes available");
				if(downloaderAvailableBytes > 0)
				{
					// buffer the downloaded bytes
					var downloadInput:IDataInput = downloader.getBytes(downloaderAvailableBytes);
					if(downloadInput != null)
					{
						downloadInput.readBytes(_bestEffortSeekBuffer, _bestEffortSeekBuffer.length, downloaderAvailableBytes);
					}
					else
					{
						trace("Got null download input.");
					}
					
					// Resetp arsing process.
					_bestEffortFileHandler.beginProcessFile(false, 0.0);

					// feed the bytes to our f4f handler in order to parse out the bootstrap box.
					trace("processing segment");
					_bestEffortFileHandler.processFileSegment(_bestEffortSeekBuffer); 

					_bestEffortFileHandler.endProcessFile(_bestEffortSeekBuffer);

					if(_bestEffortDownloadReply == HTTPStreamingEvent.DOWNLOAD_CONTINUE)
					{
						// we're done parsing and the HTTPStreamSource is going to process the file,
						// restore the contents of the downloader
						downloader.clearSavedBytes();
						_bestEffortSeekBuffer.position = 0;
						downloader.appendToSavedBytes(_bestEffortSeekBuffer, _bestEffortSeekBuffer.length);
						_bestEffortSeekBuffer.length = 0; // release the buffer
					}
					else
					{
						// Clean up on skip.
						_bestEffortSeekBuffer.length = 0;
					}
				}
				else
				{
					trace("No bytes available in best effort downloader");
				}
			}
			catch(e:Error)
			{
				trace("Failed to parse best effort segment due to " + e.toString() + "\n " + e.getStackTrace());
			}
		}

		protected function onBestEffortParsed(e:Event):void
		{
			// Currently a nop.
			trace("Got duration from best effort segment: " + _bestEffortFileHandler.segmentUri);

			// Try again.
			stalled = false;

			// Update DVR info in case we gained knowledge.
			dispatchDVRStreamInfo();
		}
		
		
		/**
		 * @private
		 * 
		 * Invoked on HTTPStreamingEvent.DOWNLOAD_COMPLETE for best effort downloads
		 */
		private function onBestEffortDownloadComplete(event:HTTPStreamingEvent):void
		{
			if(_bestEffortDownloaderMonitor == null ||
				_bestEffortDownloaderMonitor != event.target as IEventDispatcher)
			{
				// we're receiving an event for a download we abandoned
				trace("Got event for abandoned best effort download!");
				return;
			}

			trace("Best effort download complete " + event.toString());
			
			// unregister the listeners
			stopListeningToBestEffortDownload();
			
			trace("Start download parse");
			bufferAndParseDownloadedBestEffortBytes(event.url, event.downloader);
			trace("end download parse");

			// forward the DOWNLOAD_COMPLETE to HTTPStreamSource, but change the reason
			var clone:HTTPStreamingEvent = new HTTPStreamingEvent(
				event.type,
				event.bubbles,
				event.cancelable,
				event.fragmentDuration,
				event.scriptDataObject,
				event.scriptDataMode,
				event.url,
				event.bytesDownloaded,
				HTTPStreamingEventReason.BEST_EFFORT,
				event.downloader);
			dispatchEvent(clone);

			// Always skip for now.
			skipBestEffortFetch(_bestEffortFileHandler.segmentUri, event.downloader);
			
		}
		
		/**
		 * @private
		 * 
		 * Invoked on HTTPStreamingEvent.DOWNLOAD_ERROR for best effort downloads
		 */
		private function onBestEffortDownloadError(event:HTTPStreamingEvent):void
		{
			if(_bestEffortDownloaderMonitor == null ||
				_bestEffortDownloaderMonitor != event.target as IEventDispatcher)
			{
				// we're receiving an event for a download we abandoned
				return;
			}

			trace("Best effort download error " + event.toString());

			// unregister our listeners
			stopListeningToBestEffortDownload();
			
			if(_bestEffortDownloadReply != null)
			{
				// special case: if we received some bytes and said "continue", but then the download failed.
				// there means there was a connection problem mid-download
				bestEffortLog("Best effort download error after we already decided to skip or continue.");
				dispatchEvent(event); // this stops playback
			}
			else if(event.reason == HTTPStreamingEventReason.TIMEOUT)
			{
				// special case: the download took too long and all the retries failed
				bestEffortLog("Best effort download timed out");
				dispatchEvent(event); // this stops playback
			}
			else
			{
				// failure due to http status code, or some other reason. resume best effort fetch
				bestEffortLog("Best effort download error.");
				++_bestEffortFailedFetches;
				skipBestEffortFetch(event.url, event.downloader);
			}
		}
		
		/**
		 * @private
		 * 
		 * After initiating a best effort fetch, call this function to tell the
		 * HTTPStreamSource that it should not continue processing the downloaded
		 * fragment.
		 * 
		 **/
		private function skipBestEffortFetch(url:String, downloader:HTTPStreamDownloader):void
		{
			if(_bestEffortDownloadReply != null)
			{
				bestEffortLog("Best effort wanted to skip fragment, but we already replied with "+_bestEffortDownloadReply);
				return;
			}

			bestEffortLog("Best effort skipping fragment.");
			var event:HTTPStreamingEvent = new HTTPStreamingEvent(HTTPStreamingEvent.DOWNLOAD_SKIP,
				false, // bubbles
				false, // cancelable
				0, // fragmentDuration
				null, // scriptDataObject
				FLVTagScriptDataMode.NORMAL, // scriptDataMode 
				url, // url
				0, // bytesDownloaded
				HTTPStreamingEventReason.BEST_EFFORT, // reason
				downloader); // downloader
			dispatchEvent(event);
			
			_bestEffortDownloadReply = HTTPStreamingEvent.DOWNLOAD_SKIP;
		}
		
		/**
		 * @private
		 * 
		 * After initiating a best effort fetch, call this function to tell the
		 * HTTPStreamSource that it may continue processing the downloaded fragment.
		 * A continue event is assumed to mean that best effort fetch is complete.
		 **/
		private function continueBestEffortFetch(url:String, downloader:HTTPStreamDownloader):void
		{
			if(_bestEffortDownloadReply != null)
			{
				bestEffortLog("Best effort wanted to continue, but we're already replied with "+_bestEffortDownloadReply);
				return;
			}
			bestEffortLog("Best effort received a desirable fragment.");
			
			var event:HTTPStreamingEvent = new HTTPStreamingEvent(HTTPStreamingEvent.DOWNLOAD_CONTINUE,
				false, // bubbles
				false, // cancelable
				0, // fragmentDuration
				null, // scriptDataObject
				FLVTagScriptDataMode.NORMAL, // scriptDataMode 
				url, // url
				0, // bytesDownloaded
				HTTPStreamingEventReason.BEST_EFFORT, // reason
				downloader); // downloader
			
			CONFIG::LOGGING
			{
				//logger.debug("Setting _bestEffortLivenessRestartPoint to "+_bestEffortLivenessRestartPoint+" because of successful BEF download.");
				;
			}
			
			// remember that we started a download now
			_bestEffortLastGoodFragmentDownloadTime = new Date();
			
			dispatchEvent(event);
			_bestEffortDownloadReply = HTTPStreamingEvent.DOWNLOAD_CONTINUE;
			_bestEffortState = BEST_EFFORT_STATE_OFF;
		}
		
		/**
		 * @private
		 * 
		 * After initiating a best effort fetch, call this function to tell the
		 * HTTPStreamSource that a bad download error occurred. This causes HTTPStreamSource
		 * to stop playback with an error.
		 **/
		private function errorBestEffortFetch(url:String, downloader:HTTPStreamDownloader):void
		{
			bestEffortLog("Best effort fetch error.");
			var event:HTTPStreamingEvent = new HTTPStreamingEvent(HTTPStreamingEvent.DOWNLOAD_ERROR,
				false, // bubbles
				false, // cancelable
				0, // fragmentDuration
				null, // scriptDataObject
				FLVTagScriptDataMode.NORMAL, // scriptDataMode 
				url, // url
				0, // bytesDownloaded
				HTTPStreamingEventReason.BEST_EFFORT, // reason
				downloader); // downloader
			dispatchEvent(event);
			_bestEffortDownloadReply = HTTPStreamingEvent.DOWNLOAD_ERROR;
		}
		
		/**
		 * @private
		 * logging related to best effort fetch
		 **/
		private function bestEffortLog(s:String):void
		{
			trace("BEST EFFORT: "+s);
		}
		
		/**
		 * @inheritDoc
		 */	
		public override function get isBestEffortFetchEnabled():Boolean
		{
			return _bestEffortEnabled;
		}
	}
}