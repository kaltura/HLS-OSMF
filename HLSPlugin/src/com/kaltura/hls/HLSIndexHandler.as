package com.kaltura.hls
{
	import com.kaltura.hls.m2ts.IExtraIndexHandlerState;
	import com.kaltura.hls.m2ts.M2TSFileHandler;
	import com.kaltura.hls.manifest.HLSManifestEncryptionKey;
	import com.kaltura.hls.manifest.HLSManifestParser;
	import com.kaltura.hls.manifest.HLSManifestSegment;
	
	import flash.events.Event;
	import flash.events.IOErrorEvent;
	import flash.events.TimerEvent;
	import flash.utils.Timer;
	
	import org.osmf.events.DVRStreamInfoEvent;
	import org.osmf.events.HTTPStreamingEvent;
	import org.osmf.events.HTTPStreamingIndexHandlerEvent;
	import org.osmf.media.MediaResourceBase;
	import org.osmf.net.DynamicStreamingItem;
	import org.osmf.net.httpstreaming.HTTPStreamRequest;
	import org.osmf.net.httpstreaming.HTTPStreamRequestKind;
	import org.osmf.net.httpstreaming.HTTPStreamingFileHandlerBase;
	import org.osmf.net.httpstreaming.HTTPStreamingIndexHandlerBase;
	import org.osmf.net.httpstreaming.dvr.DVRInfo;
	import org.osmf.net.httpstreaming.flv.FLVTagScriptDataMode;
	import org.osmf.net.httpstreaming.flv.FLVTagScriptDataObject;
	
	public class HLSIndexHandler extends HTTPStreamingIndexHandlerBase implements IExtraIndexHandlerState
	{
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
				reloadTimer = new Timer(man.segments[man.segments.length-1].duration * 1000);
				reloadTimer.addEventListener(TimerEvent.TIMER, onReloadTimer);
				reloadTimer.start();
			}
		}
		
		private function onReloadTimer(event:TimerEvent):void
		{
			if (targetQuality != lastQuality)
				reload(targetQuality);
			else
				reload(lastQuality);
		}
		
		private function reload(quality:int):void
		{
			if (reloadTimer)
				reloadTimer.stop(); // In case the timer is active - don't want to do another reload in the middle of it
			reloadingQuality = quality;
			var manToReload:HLSManifestParser = getManifestForQuality(reloadingQuality);
			reloadingManifest = new HLSManifestParser();
			reloadingManifest.type = manToReload.type;
			reloadingManifest.addEventListener(Event.COMPLETE, onReloadComplete);
			reloadingManifest.addEventListener(IOErrorEvent.IO_ERROR, onReloadError);
			reloadingManifest.reload(manToReload);
		}
		
		private function onReloadError(event:Event):void
		{
			if(reloadTimer && !reloadTimer.running)
				reloadTimer.start();
		}
		private function onReloadComplete(event:Event):void
		{
			trace ("::onReloadComplete - last/reload/target: " + lastQuality + "/" + reloadingQuality + "/" + targetQuality);
			var newManifest:HLSManifestParser = event.target as HLSManifestParser;
			if (newManifest)
			{
				// Set the timer delay to the most likely possible delay
				if (reloadTimer) reloadTimer.delay = newManifest.segments[newManifest.segments.length - 1].duration * 1000;
				
				// remove the reload completed listener since this might become the new manifest
				newManifest.removeEventListener(Event.COMPLETE, onReloadComplete);
				
				var currentManifest:HLSManifestParser = getManifestForQuality(reloadingQuality);
				
				var timerOnErrorDelay:Number = currentManifest.targetDuration * 1000  / 2;
				
				// If we're not switching quality
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
				else if (reloadingQuality == targetQuality)
				{
					if (!updateManifestSegmentsQualityChange(newManifest, reloadingQuality) && reloadTimer != null)
						reloadTimer.delay = timerOnErrorDelay;
				}

			}
			dispatchDVRStreamInfo();
			reloadingManifest = null; // don't want to hang on to it
			if (reloadTimer) reloadTimer.start();
		}
		
		// TODO: See if there are common bits of updateManifestSegmentsQualityChange() && updateManifestSegments() that
		// can be shared
		private function updateManifestSegmentsQualityChange(newManifest:HLSManifestParser, quality:int):Boolean
		{
			if (newManifest == null || newManifest.segments.length == 0) return true;
			var lastQualityManifest:HLSManifestParser = getManifestForQuality(lastQuality);
			var targetManifest:HLSManifestParser = getManifestForQuality(quality);
			
			var lastQualitySegments:Vector.<HLSManifestSegment> = lastQualityManifest.segments;
			var targetSegments:Vector.<HLSManifestSegment> = targetManifest.segments;
			var newSegments:Vector.<HLSManifestSegment> = newManifest.segments;
			
			var matchSegment:HLSManifestSegment = lastQualitySegments[lastSegmentIndex];
			
			
			
			// Add the new manifest segments to the targetManifest
			// Goals: (not in order)
			//	1) Figure out what the start time of the new manifest is
			//	2) Append the newManifest to the targetManifest
			// 	3) Match lastQuality segments to the targetManifest segments by id
			//		a) set the seg start time
			//		b) set the seg era
			//	4) figure out what the new "lastSegmentIndex" is
			//	5) set lastQuality to the target quality
			
			// Starting with adjusting the segment values (so we only have to go through the new manifest info instead of the whole list)
			
			// Find the first segment (by id) of the new list in the lastQuality list by running backward through the lastQuality list
			var matchIndex:int = 0;
			var matchEra:int = 0;
			var matchStartTime:Number = 0;
			for (var i:int = lastQualitySegments.length - 1; i >= 0; --i)
			{
				if (lastQualitySegments[i].id == newSegments[0].id)
				{
					matchIndex = i;
					matchEra = lastQualitySegments[i].continuityEra;
					matchStartTime = lastQualitySegments[i].startTime;
					break;
				}
			}
			
			// Run through the new segments and fix up the start time, continuity era, and... hmm
			var nextStartTime:Number = matchStartTime;
			for (i = 0; i < newSegments.length; ++i)
			{
				newSegments[i].continuityEra += matchEra;
				newSegments[i].startTime = nextStartTime;
				nextStartTime += newSegments[i].duration;
			}
			
			// This is now where our new playlist starts
			lastKnownPlaylistStartTime = matchStartTime;
			
			// Append the new manifest segments to the targetManifest
			var idx:int = 0;
			if (newSegments[0].id < targetSegments[targetSegments.length - 1].id)
			{
				for (i = targetSegments.length - 1; i >= 0; --i)
				{
					if (targetSegments[i].id == newSegments[0].id)
					{
						idx = i;
						break;
					}
				}
			}
			else
			{
				idx = targetSegments.length;
			}
			
			targetSegments.length = idx; // kill any matching segments since the start times and era will possibly be wrong
			for (i = 0; i < newSegments.length; ++i)
			{
				targetSegments.push(newSegments[i]);
			}
			
			// Figure out what the new lastSegmentIndex is
			var found:Boolean = false;
			for (i = 0; i < targetSegments.length; ++i)
			{
				if (targetSegments[i].id == matchSegment.id)
				{
					lastSegmentIndex = i;
					found = true;
					stalled = false;
					break;
				}
			}
			
			if (!found && targetSegments[targetSegments.length-1].id < matchSegment.id)
			{
				stalled = true; // We want to stall because we don't know what the index should be as our new playlist is not quite caught up
				return found; // Returning early so that we don't change lastQuality (we still need that value around)
			}
			else if (!found && targetSegments[targetSegments.length - 1].id > lastQualitySegments[lastSegmentIndex].id)
			{
				// The new playlist is so far ahead of the old playlist that the item we wanted to play is gone. So go to the
				// first new index
				lastSegmentIndex = idx;
				found = true;
			}
			
			// set lastQuality to targetQuality since we're finally all matched up
			lastQuality = quality;
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

			
			// Seek forward from the lastindex of the list (no need to start from 0) to match continuity eras
			var i:int = 0;
			var k:int = 0;
			var continuityOffset:int = 0;
			var newStartTime:int = 0;
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
			
			
			// append the remaining segments to the existing segment list
			for (k = 0; k < newManifest.segments.length; ++k)
			{
				segments.push(newManifest.segments[k]);
			}
			
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
			
			// If no video streams found, but segments are, we're probably an audio playlist
			// HACK THE PLANET!!!
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
				
				if(curSegment.duration >= time - accum)
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
			quality = getWorkingQuality(quality);
			
			var segments:Vector.<HLSManifestSegment> = getSegmentsForQuality( quality );
			lastSegmentIndex++;
			
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
			else return new HTTPStreamRequest(HTTPStreamRequestKind.DONE);
		}
		
		public function getKeyForIndex( index:uint ):HLSManifestEncryptionKey
		{
			var keys:Vector.<HLSManifestEncryptionKey> = getManifestForQuality( lastQuality ).keys;
			
			for ( var i:int = 0; i < keys.length; i++ )
			{
				var key:HLSManifestEncryptionKey = keys[ i ];
				if ( key.startSegmentId <= index && key.endSegmentId > index )
				{
					if ( !key.isLoaded ) key.load();
					return key;
				}
			}
			
			return null;
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
			var segment:HLSManifestSegment = segments[segments.length - 1];
			
			var dvrInfo:DVRInfo = new DVRInfo();
			dvrInfo.offline = false
			dvrInfo.isRecording = curManifest.streamEnds;  // TODO: verify that this is what we REALLY want to be doing
			
			dvrInfo.startTime = 0;			
			dvrInfo.beginOffset = lastKnownPlaylistStartTime;
			dvrInfo.endOffset = segment.startTime + segment.duration;
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
			else return manifest.streams[quality].manifest;
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
			return "/" + sequenceSkips + "/" + lastQuality + "/" + getSegmentsForQuality(lastQuality)[lastSegmentIndex].continuityEra;
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