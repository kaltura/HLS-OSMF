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
	import flash.utils.ByteArray;
	import flash.utils.IDataInput;
	import flash.utils.Timer;
	
	import org.osmf.events.DVRStreamInfoEvent;
	import org.osmf.events.HTTPStreamingEvent;
	import org.osmf.events.HTTPStreamingEventReason;
	import org.osmf.events.HTTPStreamingIndexHandlerEvent;
	import org.osmf.logging.Log;
	import org.osmf.logging.Logger;
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
	
	public class HLSIndexHandler extends HTTPStreamingIndexHandlerBase implements IExtraIndexHandlerState
	{
		// Time in seconds to wait before retrying a LIVE_STALL
		public static const RETRY_INTERVAL:uint = 3;
		
		// Set when we rewrote the current seek target.
		public var bumpedTime:Boolean = false;
		// The new current seek target.
		public var bumpedSeek:Number = 0;

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
		private var lastSequence:int = 0;
		
		private var changeHandler:HLSQualityChangeHandler = new HLSQualityChangeHandler(getKeyForIndex);

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
		}
		
		/**
		 * Returns whether or not the times of a specific manifest has been initialized 
		 */
		private function getManifestTimeInitialized(quality:int):Boolean
		{
			if ( manifest.streams.length < 1 || manifest.streams[0].manifest == null )
			{
				return manifest.timeInitialized;
			}
			
			return manifest.streams[quality].manifest.timeInitialized;
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

		public static function getSegmentContainingTime(segments:Vector.<HLSManifestSegment>, time:Number):HLSManifestSegment
		{
			// Find matches.
			for(var i:int=0; i<segments.length; i++)
			{
				var seg:HLSManifestSegment = segments[i];
				if(seg.startTime <= time && time <= (seg.startTime + seg.duration))
					return seg;
			}

			// No match, dump to aid debug.
			for(i=0; i<segments.length-1; i++)
			{
				seg = segments[i];
				trace("#" + i + " id=" + seg.id + " start=" + seg.startTime + " end=" + (seg.startTime + seg.duration));
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
			
			changeHandler.addEventListener(HTTPStreamingEvent.DOWNLOAD_COMPLETE, passUpChangeHandlerEvent);
			changeHandler.addEventListener(HTTPStreamingEvent.DOWNLOAD_ERROR, passUpChangeHandlerEvent);
			changeHandler.addEventListener(HTTPStreamingEvent.DOWNLOAD_CONTINUE, passUpChangeHandlerEvent);
			changeHandler.addEventListener(HTTPStreamingEvent.DOWNLOAD_SKIP, passUpChangeHandlerEvent);
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

			// Check if we have knowledge of our stream, this will initiate a best effor request if not
			changeHandler.checkAnySegmentKnowledge(getManifestForQuality(lastQuality).segments);

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
			
			// If we're not switching quality or going to a backup stream
			if (reloadingQuality == lastQuality)
			{
				// Do nothing.
			}
			else if (reloadingQuality == targetQuality)
			{
				if (changeHandler.getNewQualityLevelKnowlege(currentManifest, newManifest, lastQuality, reloadingQuality))
				{
					// re-reload.
					reloadingManifest = null; // don't want to hang on to this one.
					if (reloadTimer) reloadTimer.start();
					return
				}

			}

			// Remap time.
			if(reloadingQuality != lastQuality)
			{
				changeHandler.remapTime(currentManifest, newManifest, lastSequence); 
			}

			// Update our manifest for this quality level.
			trace("Setting quality to " + reloadingQuality);
			if(manifest.streams.length)
				manifest.streams[reloadingQuality].manifest = newManifest;
			else
				manifest = newManifest;
			lastQuality = reloadingQuality;

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
			for(var i:int=0; i<resource.streamItems.length; i++)
			{
				var curStream:DynamicStreamingItem = resource.streamItems[i];
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
			
			// The requested quality doesn't match either the targetQuality or the lastQuality, which means this is new territory.
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

			// If it's the initial MAX_VALUE see, we can jump to last segment less 3.
			if(time == Number.MAX_VALUE && segments.length > 0)
			{
				trace("Seeking to end due to MAX_VALUE.");
				lastSequence = int.MAX_VALUE;
			}
	
			if(!changeHandler.checkAnySegmentKnowledge(segments))
			{
				// We may also need to establish a timebase.
				trace("Seeking without timebase; initiating request.")
				return changeHandler.firePendingBestEffortRequest();
			}

			if(time < segments[0].startTime)
			{
				trace("::getFileForTime - SequenceSkip - time: " + time + " playlistStartTime: " + segments[0].startTime);				
				time = segments[0].startTime;   /// TODO: HACK Alert!!! < this should likely be handled by DVRInfo (see dash plugin index handler)
												/// No longer quite so sure this is a hack, but a requirement
				++sequenceSkips;

				//bumpedTime = true;
				//bumpedSeek = time;
			}

			var seq:int = getSegmentSequenceContainingTime(segments, time);

			if(seq == -1 && segments.length >= 2)
			{
				trace("Got out of bound timestamp. Trying to recover...");

				var lastSeg:HLSManifestSegment = segments[segments.length - 1];
				if(segments.length >=4 )
					lastSeg = segments[segments.length - 3];

				if(time < segments[0].startTime)
				{
					trace("Fell off oldest segment, going to end #" + segments[0].id)
					seq = segments[0].id;
					//bumpedTime = true;
				}
				else if(time > lastSeg.startTime)
				{
					trace("Fell off oldest segment, going to end #" + lastSeg.id)
					seq = lastSeg.id;
					//bumpedTime = true;
				}
			}

			if(seq != -1)
			{
				var curSegment:HLSManifestSegment = getSegmentBySequence(segments, seq);
				
				lastSequence = seq;

				//bumpedSeek = curSegment.startTime;

				fileHandler.segmentId = seq;
				fileHandler.key = getKeyForIndex( seq );
				fileHandler.segmentUri = curSegment.uri;
				trace("Getting Segment[" + lastSequence + "] StartTime: " + curSegment.startTime + " Continuity: " + curSegment.continuityEra + " URI: " + curSegment.uri); 
				return createHTTPStreamRequest( curSegment );
			}
			else
			{
				trace("Seeking to unknown location " + time + ", waiting.");
			}
			
			// TODO: Handle live streaming lists by returning a stall.			
			if (!resource.manifest.streamEnds)
				return new HTTPStreamRequest (HTTPStreamRequestKind.LIVE_STALL);
			
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
			if(changeHandler.pendingBestEffortRequest)
			{
				return changeHandler.firePendingBestEffortRequest();
			}

			// Report stalls and/or wait on timebase establishment.
			if (changeHandler.stalled || changeHandler.bestEffortDownloaderMonitor)
			{
				trace("Stalling -- quality[" + quality + "] lastQuality[" + lastQuality + "]");
				return new HTTPStreamRequest(HTTPStreamRequestKind.LIVE_STALL);
			}

			HLSHTTPNetStream.recoveryStateNum = URLErrorRecoveryStates.NEXT_SEG_ATTEMPTED;
			
			//trace("Pre GWQ " + quality);
			var origQuality:int = quality;
			quality = getWorkingQuality(quality);

			var currentManifest:HLSManifestParser = getManifestForQuality ( origQuality );
			var oldManifest:HLSManifestParser = getManifestForQuality ( lastQuality ); // Use of "lastQuality" is redundant

			var segments:Vector.<HLSManifestSegment> = currentManifest.segments;
			var oldSegments:Vector.<HLSManifestSegment> = oldManifest.segments;

			// If no knowledge available, cue up a best effort fetch.
			if(!changeHandler.checkAnySegmentKnowledge(segments))
			{
				trace("Lack timebase for this manifest...");
				if(!changeHandler.bestEffortDownloaderMonitor)
				{
					trace("Initiating best effort request");
					return changeHandler.firePendingBestEffortRequest();
				}
				else
				{
					trace("Best effort request pending, so stalling.");
					return new HTTPStreamRequest(HTTPStreamRequestKind.LIVE_STALL, null, RETRY_INTERVAL);
				}
			}

			if(!changeHandler.checkAnySegmentKnowledge(oldSegments))
			{
				trace("Lack timebase for this manifest...");
				if(!changeHandler.bestEffortDownloaderMonitor)
				{
					trace("Initiating best effort request");
					return changeHandler.firePendingBestEffortRequest();
				}
				else
				{
					trace("Best effort request pending, so stalling.");
					return new HTTPStreamRequest(HTTPStreamRequestKind.LIVE_STALL, null, RETRY_INTERVAL);
				}
			}

			// Stall if we aren't ready to go.
			if(quality != origQuality && manifest.streamEnds == false)
			{
				trace("Stalling for manifest -- quality[" + quality + "] lastQuality[" + lastQuality + "]");
				return new HTTPStreamRequest(HTTPStreamRequestKind.LIVE_STALL);				
			}

			if(lastSequence == int.MAX_VALUE)
			{
				trace("Catching seek-to-end!");
				lastSequence = segments[Math.max(0, segments.length - 3)].id;
				bumpedTime = true;
				bumpedSeek = segments[Math.max(0, segments.length - 3)].startTime;
			}
			else
			{
				// Advance sequence number.
				lastSequence++;				
			}

			// Remap time immediately if needed and we're not on a DVR.
			if(origQuality != lastQuality && quality == origQuality)
			{
				changeHandler.remapTime(oldManifest, currentManifest, lastSequence); 
			}

			if( segments.length > 0 && lastSequence < segments[0].id)
			{
				trace("Resetting too low sequence " + lastSequence + " to " + segments[0].id);
				lastSequence = segments[0].id;
				//bumpedTime = true;
			}

			if (segments.length > 2 && lastSequence > (segments[segments.length-1].id + 3))
			{
				trace("Got in a bad state of " + lastSequence + " , resetting to near end of stream " + segments[segments.length-2].id);
				lastSequence = segments[segments.length-2].id;
			}

			var curSegment:HLSManifestSegment = getSegmentBySequence(segments, lastSequence);
			if ( curSegment != null ) 
			{
				trace("Getting Next Segment[" + lastSequence + "] StartTime: " + curSegment.startTime + " Continuity: " + curSegment.continuityEra + " URI: " + curSegment.uri);
				
				//bumpedSeek = curSegment.startTime;

				fileHandler.segmentId = lastSequence;
				fileHandler.key = getKeyForIndex( lastSequence );
				fileHandler.segmentUri = curSegment.uri;

				return createHTTPStreamRequest( curSegment );
			}
			
			if ( reloadingManifest || !manifest.streamEnds )
			{
				trace("Stalling -- requested segment " + lastSequence + " past the end " + segments[segments.length-1].id + " and we're in a live stream");
				lastSequence--;

				return new HTTPStreamRequest(HTTPStreamRequestKind.LIVE_STALL, null, segments[segments.length-1].duration / 2);
			}
			
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

			var segments:Vector.<HLSManifestSegment> = getSegmentsForQuality(lastQuality);
			var activeManifest:HLSManifestParser = getManifestForQuality(lastQuality);

			if(segments.length > 0)
				lastKnownPlaylistStartTime = segments[0].startTime;

			var i:int = segments.length - 1;
			if (i >= 0 && (activeManifest.allowCache || activeManifest.streamEnds))
			{
					accum = (segments[i].startTime + segments[i].duration) - lastKnownPlaylistStartTime;
			}
			
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
			var segments:Vector.<HLSManifestSegment> = getSegmentsForQuality(lastQuality);
			if (segments.length == 0) return; // No point, I think, in continuing
			
			var firstSegment:HLSManifestSegment = segments[ 0 ];
			var lastSegment:HLSManifestSegment = segments[segments.length - 1];
			
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
		
		private function passUpChangeHandlerEvent(event:HTTPStreamingEvent):void
		{
			// Simply pass up the event
			dispatchEvent(event);
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
				return changeHandler.updateSegmentTimes(manifest.segments); // There is one quality, that is implicitly 0
			}
			else if ( quality >= manifest.streams.length ) return changeHandler.updateSegmentTimes(manifest.streams[0].manifest.segments);
			else return changeHandler.updateSegmentTimes(manifest.streams[quality].manifest.segments);
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
			var segments:Vector.<HLSManifestSegment> = getSegmentsForQuality(lastQuality);
			
			if (segments.length == 0)
			{
				var returnString:String = "/" + sequenceSkips + "/" + lastQuality + "/0";
				trace("WARNING: There are 0 segments in the last quality, generating Continuity Token \"" + returnString + "\"");
				return returnString;
			}
			
			if (lastSequence > segments[segments.length - 1].id || lastSequence < 0)
			{
				trace("==WARNING: lastSegmentIndex is greater than number of segments in last quality==");
				trace("lastSegmentIndex: " + lastSequence + " | max allowed index: " + segments[segments.length - 1].id);
				trace("Setting lastSegmentIndex to " + segments[segments.length - 1].id);
				lastSequence = segments[segments.length - 1].id;

				// Back off by one as it will get incremented later.
				lastSequence--;
			}
			
			var lastSeg:HLSManifestSegment = getSegmentBySequence(segments, lastSequence);
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
			var segments:Vector.<HLSManifestSegment> = getSegmentsForQuality( lastQuality );
			var segment:HLSManifestSegment = getSegmentBySequence( segments, lastSequence );

			return segment ? segment.startTime : 0.0;
		}
		
		public function getTargetSegmentDuration():Number
		{
			return getManifestForQuality(lastQuality).targetDuration;
		}
		
		
	}
}