package com.kaltura.hls
{
	import com.kaltura.hls.HLSIndexHandler;
	import com.kaltura.hls.m2ts.M2TSFileHandler;
	import com.kaltura.hls.manifest.HLSManifestEncryptionKey;
	import com.kaltura.hls.manifest.HLSManifestParser;
	import com.kaltura.hls.manifest.HLSManifestSegment;
	
	import flash.events.Event;
	import flash.events.EventDispatcher;
	import flash.events.IEventDispatcher;
	import flash.utils.ByteArray;
	import flash.utils.IDataInput;
	
	import org.osmf.events.HTTPStreamingEvent;
	import org.osmf.events.HTTPStreamingEventReason;
	import org.osmf.net.httpstreaming.HTTPStreamDownloader;
	import org.osmf.net.httpstreaming.HTTPStreamRequest;
	import org.osmf.net.httpstreaming.HTTPStreamRequestKind;
	import org.osmf.net.httpstreaming.flv.FLVTagScriptDataMode;

	public class HLSQualityChangeHandler extends EventDispatcher
	{
		/***** Static *****/
		public static var indexTimingData:HLSQualityChangeHandlerData = new HLSQualityChangeHandlerData();
		
		/***** Variables *****/
		private var _pendingBestEffortRequest:HTTPStreamRequest = null;
		private var _stalled:Boolean = false;
		
		private var keyFunction:Function;
		
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
		
		// constants used by getNextRequestForBestEffortPlay:
		private static const BEST_EFFORT_PLAY_SITUATION_NORMAL:String = "normal";
		private static const BEST_EFFORT_PLAY_SITUATION_DROPOUT:String = "dropout";
		private static const BEST_EFFORT_PLAY_SITUATION_LIVENESS:String = "liveness";
		private static const BEST_EFFORT_PLAY_SITUATION_DONE:String = "done";
		
		/***** Public API *****/
		
		public function HLSQualityChangeHandler(keyFunc:Function)
		{
			_bestEffortFileHandler.addEventListener(HTTPStreamingEvent.FRAGMENT_DURATION, onBestEffortParsed);
			_bestEffortFileHandler.isBestEffort = true;
			
			keyFunction = keyFunc;
		}
		
		/**
		 * Takes a set of segments and updates their times using the existing index timing data, then returns
		 * the altered segments
		 */
		public function updateSegmentTimes(segments:Vector.<HLSManifestSegment>):void
		{
			// Using our witnesses, fill in as much knowledge as we can about 
			// segment start/end times.
			
			// First, set any exactly known values.
			var knownIndex:int = -1;
			for(var i:int=segments.length-1; i>=0; i--)
			{
				// Skip unknowns.
				if(!indexTimingData.startTimeWitnesses.hasOwnProperty(segments[i].uri))
					continue;
				
				segments[i].startTime = indexTimingData.startTimeWitnesses[segments[i].uri];
				if (knownIndex == -1) knownIndex = i;
			}
			
			// Now that exactly known values are set, find the latest known time and
			// go from there.
			
			if(segments.length > 1 && knownIndex != -1)
			{
				var lowestStartTime:Number;
				var highestStartTime:Number;
				
				// Then fill in any unknowns scanning forward....
				for(i=knownIndex+1; i<segments.length; i++)
				{
					segments[i].startTime = segments[i-1].startTime + segments[i-1].duration;
				}
				
				highestStartTime = segments[i-1].startTime;
				
				// And scanning back...
				for(i=knownIndex-1; i>=0; i--)
				{
					segments[i].startTime = segments[i+1].startTime - segments[i].duration;
				}
				
				lowestStartTime = segments[i+1].startTime;
			}
			
			trace("Reconstructed manifest time with knowledge=" + checkAnySegmentKnowledge(segments) + " firstTime=" + (segments.length > 1 ? segments[0].startTime : -1) + " lastTime=" + (segments.length > 1 ? segments[segments.length-1].startTime : -1));
			
			// Done!
			return segments;
		}
		
		public function getNewQualityLevelKnowlege(currentManifest:HLSManifestParser, newManifest:HLSManifestParser, lastQuality:int, reloadingQuality:int):Boolean
		{
			// If we are going to a quality level we don't know about, go ahead
			// and best-effort-fetch a segment from it to establish the timebase.
			var newManifestKnowlege:Boolean = checkAnySegmentKnowledge(newManifest.segments);
			var currentManifestKnowledge:Boolean = checkAnySegmentKnowledge(currentManifest.segments);
			if(!newManifestKnowlege && !_bestEffortDownloaderMonitor)
			{
				trace("(A) Encountered a live/VOD manifest with no timebase knowledge, request newest segment via best effort path for quality " + reloadingQuality);
			} else if(!currentManifestKnowledge && !_bestEffortDownloaderMonitor)
			{
				trace("(B) Encountered a live/VOD manifest with no timebase knowledge, request newest segment via best effort path for quality " + reloadingQuality);
			}
			
			if(!newManifestKnowlege || !currentManifestKnowledge)
			{
				trace("Bailing on reload due to lack of knowledge!");
				
				return true;
			}
			
			return false;
		}
		
		public function remapTime(currentManifest:HLSManifestParser, newManifest:HLSManifestParser, lastSequence:int):void
		{
			updateSegmentTimes(currentManifest.segments);
			updateSegmentTimes(newManifest.segments);
			
			const fudgeTime:Number = 1.0;
			var lastSeg:HLSManifestSegment = HLSIndexHandler.getSegmentBySequence(currentManifest.segments, lastSequence);
			var newSeg:HLSManifestSegment = lastSeg ? HLSIndexHandler.getSegmentContainingTime(newManifest.segments, lastSeg.startTime + lastSeg.duration) : null;
			if(newSeg == null)
			{
				trace("Remapping from " + lastSequence);
				
				if(lastSeg)
				{
					// Guess by time....
					trace("Found last seg with startTime = " + lastSeg.startTime + " duration=" + lastSeg.duration);
					
					// If the segment is beyond last ID, then jump to end...
					if(lastSeg.startTime + lastSeg.duration >= newManifest.segments[newManifest.segments.length-1].startTime)
					{
						trace("ERROR: Couldn't remap sequence to new quality level, restarting at last time " + newManifest.segments[newManifest.segments.length-1].startTime);
						lastSequence = newManifest.segments[newManifest.segments.length-1].id;
					}
					else
					{
						trace("ERROR: Couldn't remap sequence to new quality level, restarting at first time " + newManifest.segments[0].startTime);
						lastSequence = newManifest.segments[0].id;
					}
				}
				else
				{
					// Guess by sequence number...
					trace("No last seg found");
					
					// If the segment is beyond last ID, then jump to end...
					if(lastSequence >= newManifest.segments[newManifest.segments.length-1].id)
					{
						trace("ERROR: Couldn't remap sequence to new quality level, restarting at last sequence " + newManifest.segments[newManifest.segments.length-1].id);
						lastSequence = newManifest.segments[newManifest.segments.length-1].id;
					}
					else
					{
						trace("ERROR: Couldn't remap sequence to new quality level, restarting at first sequence " + newManifest.segments[0].id);
						lastSequence = newManifest.segments[0].id;
					}
				}
			}
			else
			{
				trace("Remapping from " + lastSequence + " to " + lastSeg.startTime + "-" + (lastSeg.startTime + lastSeg.duration));
				trace("===== Remapping to " + lastSequence + " newId=" + (newSeg.id) + " newTime=" + newSeg.startTime + "-" + (newSeg.startTime + newSeg.duration) );
				lastSequence = newSeg.id;
			}
			
			// Dec for next time around.
			trace("   o Ended at " + lastSequence);
		}
		
		/**
		 * Return true if we have encountered any segments from this list of segments, false otherwise.
		 * If false is to be returned, will automatically attempt to initiate a best efford request
		 */
		public function checkAnySegmentKnowledge(segments:Vector.<HLSManifestSegment>):Boolean
		{
			// Find matches.
			for(var i:int=0; i<segments.length; i++)
			{
				if(indexTimingData.startTimeWitnesses.hasOwnProperty(segments[i].uri))
					return true;
			}
			
			// A match was not found, so initiate a best effort request
			if (segments.length && !bestEffortDownloaderMonitor)
				pendingBestEffortRequest = initiateBestEffortRequest(segments[segments.length-1], segments.length-1);
			
			return false;
		}
		
		public function firePendingBestEffortRequest():HTTPStreamRequest
		{
			trace("Firing pending best effort request: " + pendingBestEffortRequest);
			var pber:HTTPStreamRequest = pendingBestEffortRequest;
			pendingBestEffortRequest = null;
			return pber;
		}
		
		/***** Properties *****/
		
		public function get pendingBestEffortRequest():HTTPStreamRequest { return _pendingBestEffortRequest; }
		public function set pendingBestEffortRequest(val:HTTPStreamRequest):void { _pendingBestEffortRequest = val; }
		
		public function get stalled():Boolean { return _stalled; }
		public function set stalled(val:Boolean):void { _stalled = val; }
		
		public function get bestEffortDownloaderMonitor():EventDispatcher { return _bestEffortDownloaderMonitor; }
		
		/***** Helpers *****/
		/**
		 * @private
		 * 
		 * Initiates a best effort request (from getNextFile or getFileForTime) and constructs an HTTPStreamRequest.
		 * 
		 * @return the action to take, expressed as an HTTPStreamRequest
		 **/
		private function initiateBestEffortRequest(segment:HLSManifestSegment, keyIndex:int):HTTPStreamRequest
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
			
			if(!segment || !segment.uri)
			{
				// The segment provided is not valid!
				bestEffortLog("Invalid segment provided. Aborting: " + segment ? segment.uri : null);
				return null;
			}		
			
			_bestEffortFileHandler.segmentId = segment.id;
			_bestEffortFileHandler.key = keyFunction(keyIndex);
			_bestEffortFileHandler.segmentUri = segment.uri;
			
			var streamRequest:HTTPStreamRequest =  new HTTPStreamRequest(
				HTTPStreamRequestKind.BEST_EFFORT_DOWNLOAD,
				segment.uri, // url
				-1, // retryAfter
				_bestEffortDownloaderMonitor); // bestEffortDownloaderMonitor
			
			trace("Requesting best effort download: " + streamRequest.toString());
			
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
	}
}