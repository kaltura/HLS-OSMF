package com.kaltura.hls
{
	import com.kaltura.hls.m2ts.IExtraIndexHandlerState;
	import com.kaltura.hls.m2ts.M2TSFileHandler;
	import com.kaltura.hls.manifest.HLSManifestEncryptionKey;
	import com.kaltura.hls.manifest.HLSManifestParser;
	import com.kaltura.hls.manifest.HLSManifestSegment;
	import com.kaltura.hls.manifest.HLSManifestStream;
	
	import flash.events.Event;
	import flash.events.IOErrorEvent;
	import flash.events.TimerEvent;
	import flash.utils.Timer;
	
	import org.osmf.events.DVRStreamInfoEvent;
	import org.osmf.events.HTTPStreamingEvent;
	import org.osmf.events.HTTPStreamingIndexHandlerEvent;
	import org.osmf.media.MediaResourceBase;
	import org.osmf.net.DynamicStreamingItem;
	import org.osmf.net.httpstreaming.HLSHTTPNetStream;
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
		
		public var lastSegmentIndex:int = 0;
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
		private function reload(quality:int, manifest:HLSManifestParser = null):void
		{
			if (reloadTimer)
				reloadTimer.stop(); // In case the timer is active - don't want to do another reload in the middle of it
			reloadingQuality = quality;
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
			
			if (!swapBackupStream(quality, backupStreamNumber))
				reload(quality);
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
		private function swapBackupStream(stream:*, backupOffset:int = 0):Boolean
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
				for (var i:int = 0; i <= manifest.streams.length; i++)
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
			if (newManifest)
			{
				// Detect if there are 0 segments in the new manifest
				if (newManifest.segments.length == 0)
				{
					trace("WARNING: newManifest has 0 segments");
					return;
				}
					
				// Set the timer delay to the most likely possible delay
				if (reloadTimer) reloadTimer.delay = newManifest.segments[newManifest.segments.length - 1].duration * 1000;
				
				// remove the reload completed listener since this might become the new manifest
				newManifest.removeEventListener(Event.COMPLETE, onReloadComplete);
				
				if (reloadingQuality != -1)
					var currentManifest:HLSManifestParser = getManifestForQuality(reloadingQuality);
				
				var timerOnErrorDelay:Number = newManifest.targetDuration * 1000  / 2;
				
				// If we're not switching quality or going to a backup stream
				if (reloadingQuality == lastQuality)
				{				
					if (newManifest.mediaSequence > currentManifest.mediaSequence)
					{
						updateManifestSegments(newManifest, reloadingQuality);
					}
					else if (newManifest.mediaSequence == currentManifest.mediaSequence && newManifest.segments.length != currentManifest.segments.length)
					{
						updateManifestSegments(newManifest, reloadingQuality);
					}
					else
					{
						// the media sequence is earlier than the one we currently have, which isn't
						// allowed by the spec, or there are no changes. So do nothing, but check again as quickly as allowed
						if (reloadTimer) reloadTimer.delay = timerOnErrorDelay;
					}
				}
				else if (reloadingQuality == targetQuality || reloadingQuality == -1)
				{
					if (!updateNewManifestSegments(newManifest, reloadingQuality) && reloadTimer)
						reloadTimer.delay = timerOnErrorDelay;	
				}
			}
			
			dispatchDVRStreamInfo();
			reloadingManifest = null; // don't want to hang on to it
			if (reloadTimer) reloadTimer.start();
		}
		
		private function updateNewManifestSegments(newManifest:HLSManifestParser, quality:int):Boolean
		{
			if (newManifest == null || newManifest.segments.length == 0) return true;
	
			var lastQualityManifest:HLSManifestParser = getManifestForQuality(lastQuality);
			var targetManifest:HLSManifestParser = quality == -1 ? primaryStream.backupStream.manifest : getManifestForQuality(quality);
			
			if (newManifest.isDVR != lastQualityManifest.isDVR)
			{
				// If the new manifest's DVR status does not match the current DVR status, don't switch qualities or go to a backup
				targetQuality = lastQuality;
				return false;
			}
			
			var lastQualitySegments:Vector.<HLSManifestSegment> = lastQualityManifest.segments;
			var targetSegments:Vector.<HLSManifestSegment> = targetManifest.segments;
			
			/* Handle Buffered Segments */
			var numBuffered:int = targetManifest.bufferSegments.length;
			
			lastQualitySegments.concat(lastQualityManifest.bufferSegments);
			targetSegments.concat(targetManifest.bufferSegments);
			
			var newSegments:Vector.<HLSManifestSegment> = newManifest.segments;
			
			var matchSegment:HLSManifestSegment = lastQualitySegments[lastSegmentIndex < lastQualitySegments.length ? lastSegmentIndex : lastQualitySegments.length -1];
			
			// Add the new manifest segments to the targetManifest
			// Tasks: (in order)
			//	1) Append the new segments to the target segment list and determine the new last known playlist start time
			//  2) Determine the last segment index in the new segment list
			
			// Find the point where the new segments id matches the old segment id
			var matchId:int = targetSegments[targetSegments.length - 1].id;
			var matchIndex:int = -1;
			var matchStartTime:Number = lastKnownPlaylistStartTime;
			for (var i:int = newSegments.length - 1; i >= 0; i--)
			{
				if (newSegments[i].id == matchId)
				{
					matchIndex = i;
					break;
				}
			}
			
			// We only need to make additional calculations if we were able to find a point where the segments matched up
			if (matchIndex >= 0 && matchIndex != newSegments.length -1)
			{
				// Fix the start times
				var nextStartTime:Number = targetSegments[targetSegments.length - 1].startTime;
				for (i = matchIndex; i < newSegments.length; i++)
				{
					newSegments[i].startTime = nextStartTime;
					nextStartTime += newSegments[i].duration;
				}
				
				// Append the new manifest segments to the targetManifest
				for (i = matchIndex + 1; i < newSegments.length; ++i)
				{
					numBuffered++;
					targetSegments.push(newSegments[i]);
				}
				
				if (numBuffered > HLSManifestParser.MAX_SEG_BUFFER)
					numBuffered = HLSManifestParser.MAX_SEG_BUFFER;
				
				// Now we need to calculate the last known playlist start time
				var matchStartId:int = newSegments[0].id;
				for (i = 0; i < targetSegments.length; i++)
				{
					if (targetSegments[i].id == matchStartId)
						matchStartTime = targetSegments[i].startTime;
				}
			}
			else if (matchIndex < 0)
			{
				// The last playlist start time is at the start of the newest segment, try to find an accurate start time
				var lastQualityTimeMatchFound:Boolean = false;
				
				if (lastQualitySegments[lastQualitySegments.length - 1].id >= newSegments[0].id)
				{
					// If we have at least one ID that matches between quality levels, use that to sync up out times. It is a better solution than pure estimation
					for (var i:int = lastQualitySegments.length - 1; i >= 0; i--)
					{
						// Find the segment in the last quality level that matches the segment in the new quality level
						if (lastQualitySegments[i].id == newSegments[0].id && lastQualitySegments[i].duration == newSegments[0].duration)
						{
							matchStartTime = lastQualitySegments[i].startTime;
							lastQualityTimeMatchFound = true;
							trace ("Found Match Start Time: " + matchStartTime);
						}
					}
				}
				
				// Only do this messy estimation if we couldn't find a start time with ID matching
				if (!lastQualityTimeMatchFound)
				{
					matchStartTime += targetSegments[targetSegments.length - 1].duration * 0.5;
					
					// Let the console know that we might have a problem
					trace("Warning: Estimating playlist start time. Estimated start time: " + matchStartTime);
				}
				
				// Make a completely new buffer, we don't want the elements in the segment buffer to have a gap
				if (newSegments.length < HLSManifestParser.MAX_SEG_BUFFER)
					numBuffered = HLSManifestParser.MAX_SEG_BUFFER - 1;
				else
					numBuffered = HLSManifestParser.MAX_SEG_BUFFER;
					
				
				// No matches were found so we add all the new segments to the playlist, also adjust their start times
				nextStartTime = matchStartTime;
				for (i = 0; i < newSegments.length; i++)
				{
					newSegments[i].startTime = nextStartTime;
					nextStartTime += newSegments[i].duration;
					targetSegments.push(newSegments[i]);
				}
			}
			else
			{
				// In this case there are no new segments and we don't actually need to do anything to the playlist
			}
			
			// Re-create the segment buffer
			targetManifest.bufferSegments = targetSegments.splice(targetSegments.length - numBuffered, numBuffered);
			
			// This is now where our new playlist starts
			lastKnownPlaylistStartTime = matchStartTime;
			
			// Figure out what the new lastSegmentIndex is
			var found:Boolean = false;
			var matchTime:Number = lastQualitySegments[lastSegmentIndex].startTime;
			for (i = 0; i < targetSegments.length; ++i)
			{
				if (targetSegments[i].startTime <= matchTime && targetSegments[i].startTime > matchTime - targetSegments[i].duration)
				{
					lastSegmentIndex = i;
					found = true;
					stalled = false;
					break;
				}
			}
			
			if (!found && targetSegments[targetSegments.length-1].startTime < matchSegment.startTime)
			{
				trace("***STALL*** Target Start Time: " + targetSegments[targetSegments.length-1].startTime + "Match Start Time: " + matchSegment.startTime);
					
				stalled = true; // We want to stall because we don't know what the index should be as our new playlist is not quite caught up
				return found; // Returning early so that we don't change lastQuality (we still need that value around)
			}
			
			// Either set lastQuality to targetQuality or switch to the backup since we're finally all matched up
			if (quality == -1)
			{		
				// Find the stream to replace with its backup
				for (i = 0; i <= manifest.streams.length; i++)
				{
					if (i == manifest.streams.length)
					{
						trace ("WARNING - Backup Replacement Failed: Stream with URI " + primaryStream.uri + " not found");
						break;
					}
					
					if (manifest.streams[i] == primaryStream && manifest.streams[i].backupStream)
					{
						manifest.streams[i] = manifest.streams[i].backupStream;
						HLSHTTPNetStream.currentStream = manifest.streams[i];
						postRatesReady();
						break;
					}
				}
				HLSHTTPNetStream.hasGottenManifest = true;
			}
			else
			{
				lastQuality = targetQuality;
			}
			stalled = false;
			return found;
		}
		
		private function updateManifestSegments(newManifest:HLSManifestParser, quality:int ):void
		{
			// NOTE: If a stream uses byte ranges, the algorithm in this method will not
			// take note of them, and will likely return the same file every time. An effort
			// could also be made to do more stringent testing on the list of segments (beyond just the URI),
			// perhaps by comparing timestamps.
			
			if (newManifest == null || newManifest.segments.length == 0) return;
			
			var segments:Vector.<HLSManifestSegment> = getSegmentsForQuality( quality );
			var curManifest:HLSManifestParser = getManifestForQuality(quality);
			var segId:int= segments[segments.length - 1].id;
			
			/* Handle our segment buffer */
			var numBuffered:int = curManifest.bufferSegments.length;
			
			segments.concat(curManifest.bufferSegments);
			
			// Seek forward from the lastindex of the list (no need to start from 0) to match continuity eras
			var i:int = 0;
			var k:int = 0;
			var continuityOffset:int = 0;
			var newStartTime:Number = 0;
			for (i = 0; i < segments.length; ++i)
			{
				if (newManifest.segments[0].id == segments[i].id)
				{
					// Found the match. Now offset the eras in the new segment list by the era in the match
					continuityOffset = segments[i].continuityEra;
					newStartTime = segments[i].startTime;
					break;
				}
			}
			
			if (i == segments.length) // we didn't find a match so force a discontinuity
			{
				if (segments.length > 0)
				{
					continuityOffset = segments[segments.length-1].continuityEra + 1;
					newStartTime = segments[segments.length-1].startTime + segments[segments.length-1].duration;
				}
			}

			// store the playlist start time
			lastKnownPlaylistStartTime = newStartTime;

			// run through the new playlist and adjust the start times and continuityEras
			for (k = 0; k < newManifest.segments.length; ++k)
			{
				newManifest.segments[k].continuityEra += continuityOffset;
				newManifest.segments[k].startTime = newStartTime;
				newStartTime += newManifest.segments[k].duration;
			}
			
			// Seek backward through the new segment list until we find the one that matches
			// the last segment of the current list
			for (i = newManifest.segments.length - 1; i >= 0; --i)
			{
				if (newManifest.segments[i].id == segId)
				{
					break;
				}
			}
			
			// kill all the segments from the new list that match what we already have
			newManifest.segments.splice(0, i + 1);
			
			numBuffered += newManifest.segments.length
			
			// append the remaining segments to the existing segment list
			for (k = 0; k < newManifest.segments.length; ++k)
			{
				segments.push(newManifest.segments[k]);
			}
			
			// We only ever store the maximum allowed segments into a buffer
			if (numBuffered > HLSManifestParser.MAX_SEG_BUFFER) 
				numBuffered = HLSManifestParser.MAX_SEG_BUFFER;
			
			curManifest.bufferSegments = segments.splice(segments.length - numBuffered, numBuffered);
			
			// Match the new manifest's and the old manifest's DVR status
			getManifestForQuality(quality).streamEnds = newManifest.streamEnds;
			manifest.streamEnds = newManifest.streamEnds;
			
			updateTotalDuration();
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
			
			// If the requsted quality is the same as the target quality, we've already asked for a reload, so return the last quality
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
			quality = getWorkingQuality(quality);
			
			var accum:Number = 0.0;
			var segments:Vector.<HLSManifestSegment> = getSegmentsForQuality( quality );
			
			if (time < lastKnownPlaylistStartTime) 
			{
				time = lastKnownPlaylistStartTime;  /// TODO: HACK Alert!!! < this should likely be handled by DVRInfo (see dash plugin index handler)
													/// No longer quite so sure this is a hack, but a requirement
				++sequenceSkips;
				trace("::getFileForTime - SequenceSkip - time: " + time + " playlistStartTime: " + lastKnownPlaylistStartTime);
			}

			for(var i:int=0; i<segments.length; i++)
			{
				var curSegment:HLSManifestSegment = segments[i];
				
				if(curSegment.duration > time - accum)
				{
					lastSegmentIndex = i;
					fileHandler.segmentId = lastSegmentIndex;
					fileHandler.key = getKeyForIndex( i );
					trace("Getting Segment[" + lastSegmentIndex + "] StartTime: " + segments[i].startTime + " Continuity: " + segments[i].continuityEra + " URI: " + segments[i].uri); 
					return createHTTPStreamRequest( segments[ lastSegmentIndex ] ); 
				}
				
				accum += curSegment.duration; 
			}
			
			// TODO: Handle live streaming lists by returning a stall.
			lastSegmentIndex = i;
			
			fileHandler.segmentId = lastSegmentIndex;
			fileHandler.key = getKeyForIndex( i );
			
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
			if (stalled)
			{
				trace("Stalling -- quality[" + quality + "] lastQuality[" + lastQuality + "]");
				return new HTTPStreamRequest(HTTPStreamRequestKind.LIVE_STALL);
			}

			HLSHTTPNetStream.recoveryStateNum = URLErrorRecoveryStates.NEXT_SEG_ATTEMPTED;
			
			quality = getWorkingQuality(quality);
			
			var currentManifest:HLSManifestParser = getManifestForQuality ( quality );
			var segments:Vector.<HLSManifestSegment> = currentManifest.segments;
			lastSegmentIndex++;
			
			// Add a buffered segment if we need to and we have one
			if (lastSegmentIndex >= segments.length && currentManifest.bufferSegments.length > 0)
				segments.push( currentManifest.bufferSegments.shift() );
			
			fileHandler.segmentId = lastSegmentIndex;
			fileHandler.key = getKeyForIndex( lastSegmentIndex );

			if ( lastSegmentIndex < segments.length) 
			{
				if (segments[lastSegmentIndex].startTime + segments[lastSegmentIndex].duration < lastKnownPlaylistStartTime)
				{
					trace("::getNextFile - SequenceSkip - startTime: " + segments[lastSegmentIndex].startTime + " + duration: " + segments[lastSegmentIndex].duration  + " playlistStartTime: " + lastKnownPlaylistStartTime);
					lastSegmentIndex = getSegmentIndexForTime(lastKnownPlaylistStartTime);
					++sequenceSkips;
				}
				trace("Getting Next Segment[" + lastSegmentIndex + "] StartTime: " + segments[lastSegmentIndex].startTime + " Continuity: " + segments[lastSegmentIndex].continuityEra + " URI: " + segments[lastSegmentIndex].uri);
				
				return createHTTPStreamRequest( segments[ lastSegmentIndex ] );
			}
			
			if ( reloadingManifest || !manifest.streamEnds )
			{
				trace("Stalling -- requested segment past the end and we're in a live stream");
				lastSegmentIndex--;
				return new HTTPStreamRequest(HTTPStreamRequestKind.LIVE_STALL, null, RETRY_INTERVAL);
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
			if(!swapBackupStream(stream))
				HLSHTTPNetStream.hasGottenManifest = true;
		}
		
		private function updateTotalDuration():void
		{
			var accum:Number = NaN;
			
			if(!manifest)
				return;
			
			var segments:Vector.<HLSManifestSegment> = getSegmentsForQuality( lastQuality );
			var activeManifest:HLSManifestParser = getManifestForQuality(lastQuality);
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
			var segment:HLSManifestSegment = segments[segments.length - 1];
			
			var dvrInfo:DVRInfo = new DVRInfo();
			dvrInfo.offline = false;
			dvrInfo.isRecording = !curManifest.streamEnds;  // TODO: verify that this is what we REALLY want to be doing
			dvrInfo.startTime = firstSegment.startTime;			
			dvrInfo.beginOffset = firstSegment.startTime;
			dvrInfo.endOffset = segment.startTime; // + segment.duration;
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
			if ( manifest.streams.length < 1 || manifest.streams[0].manifest == null ) return manifest.segments;
			else if ( quality >= manifest.streams.length ) return manifest.streams[0].manifest.segments;
			else return manifest.streams[quality].manifest.segments;
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
			
			if (lastSegmentIndex >= segments.length || lastSegmentIndex < 0)
			{
				trace("==WARNING: lastSegmentIndex is greater than number of segments in last quality==");
				trace("lastSegmentIndex: " + lastSegmentIndex + " | max allowed index: " + (segments.length - 1));
				trace("Setting lastSegmentIndex to " + (segments.length - 1) + "\n");
				lastSegmentIndex = segments.length - 1;
			}
			
			return "/" + sequenceSkips + "/" + lastQuality + "/" + segments[lastSegmentIndex].continuityEra;
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
			
			if (lastSegmentIndex < segments.length)
				return segments[lastSegmentIndex].startTime;
			
			return 0.0;
		}
		
		public function getTargetSegmentDuration():Number
		{
			return getManifestForQuality(lastQuality).targetDuration;
		}
	}
}