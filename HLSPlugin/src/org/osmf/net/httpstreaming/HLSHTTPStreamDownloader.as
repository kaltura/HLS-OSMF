/*****************************************************
 *  
 *  Copyright 2011 Adobe Systems Incorporated.  All Rights Reserved.
 *  
 *****************************************************
 *  The contents of this file are subject to the Mozilla Public License
 *  Version 1.1 (the "License"); you may not use this file except in
 *  compliance with the License. You may obtain a copy of the License at
 *  http://www.mozilla.org/MPL/
 *   
 *  Software distributed under the License is distributed on an "AS IS"
 *  basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
 *  License for the specific language governing rights and limitations
 *  under the License.
 *   
 *  
 *  The Initial Developer of the Original Code is Adobe Systems Incorporated.
 *  Portions created by Adobe Systems Incorporated are Copyright (C) 2011 Adobe Systems 
 *  Incorporated. All Rights Reserved. 
 *  
 *****************************************************/
package org.osmf.net.httpstreaming
{
	import flash.events.Event;
	import flash.events.IEventDispatcher;
	import flash.events.IOErrorEvent;
	import flash.events.ProgressEvent;
	import flash.events.SecurityErrorEvent;
	import flash.events.TimerEvent;
	import flash.net.URLRequest;
	import flash.net.URLStream;
	import flash.utils.ByteArray;
	import flash.utils.IDataInput;
	import flash.utils.Timer;
	import flash.utils.getTimer;
	import flash.external.ExternalInterface;
	
	import org.osmf.events.HTTPStreamingEvent;
	import org.osmf.events.HTTPStreamingEventReason;
	import org.osmf.net.httpstreaming.flv.FLVTagScriptDataMode;
	import org.osmf.utils.OSMFSettings;

	import com.kaltura.hls.manifest.HLSManifestParser;

	CONFIG::LOGGING
	{
		import org.osmf.logging.Logger;
	}
	
	[ExcludeClass]
	
	/**
	 * @private
	 * 
	 * HLSHTTPStreamDownloader is a utility class which is responsible for
	 * downloading and local buffering HDS streams.
	 * 
	 * @langversion 3.0
	 * @playerversion Flash 10.1
	 * @playerversion AIR 1.5
	 * @productversion OSMF 1.6
	 */
	public class HLSHTTPStreamDownloader extends HTTPStreamDownloader
	{
		public static var SEND_LOGS:Boolean = false;
		
		/**
		 * Default constructor.
		 * 
		 * @param dispatcher A dispatcher object used by HLSHTTPStreamDownloader to
		 * 					 dispatch any event. 
		 **/
		public function HLSHTTPStreamDownloader()
		{
		}
		
		public function get currentDownloadSpeedInBytesPerSecond():Number
		{
			return _currentDownloadRate;
		}

		/**
		 * Returns true if the HTTP stream source is open and false otherwise.
		 **/
		public override function get isOpen():Boolean
		{
			return _isOpen;
		}
		
		/**
		 * Returns true if the HTTP stream source has been completly downloaded.
		 **/
		public override function get isComplete():Boolean
		{
			return _isComplete;
		}
		
		/**
		 * Returns true if the HTTP stream source has data available for processing.
		 **/
		public override function get hasData():Boolean
		{
			return _hasData;
		}

		/**
		 * Returns true if the HTTP stream source has not been found or has some errors.
		 */
		public override function get hasErrors():Boolean
		{
			return _hasErrors;
		}
		
		/**
		 * Returns the duration of the last download in seconds.
		 */
		public override function get downloadDuration():Number
		{
			return _downloadDuration;
		}
		
		/**
		 * Returns the bytes count for the last download.
		 */
		public override function get downloadBytesCount():Number
		{
			return _downloadBytesCount;
		}
		
		public function debugToJS(url:String, event:String):void
		{
			if ( SEND_LOGS ){
				ExternalInterface.call("onDownload", {url: url, event: event});
			}
		}
		
		/**
		 * Opens the HTTP stream source and start downloading the data 
		 * immediately. It will automatically close any previous opended
		 * HTTP stream source.
		 **/
		public override function open(request:URLRequest, dispatcher:IEventDispatcher, timeout:Number):void
		{
			if (isOpen || (_urlStream != null && _urlStream.connected))
				close();
			
			if(request == null)
			{
				throw new ArgumentError("Null request in HLSHTTPStreamDownloader open method."); 
			}
			
			debugToJS( request.url.toString(), "open");
			
			_isComplete = false;
			_hasData = false;
			_hasErrors = false;
			
			_dispatcher = dispatcher;
			if (_savedBytes == null)
			{
				_savedBytes = new ByteArray();
			}
			
			if (_urlStream == null)
			{
				_urlStream = new URLStream();
				_urlStream.addEventListener(Event.OPEN, onOpen);
				_urlStream.addEventListener(Event.COMPLETE, onComplete);
				_urlStream.addEventListener(ProgressEvent.PROGRESS, onProgress);
				_urlStream.addEventListener(IOErrorEvent.IO_ERROR, onError);
				_urlStream.addEventListener(SecurityErrorEvent.SECURITY_ERROR, onError);
			}
			
			if (_timeoutTimer == null && timeout != -1)
			{
				_timeoutTimer = new Timer(timeout, 1);
				_timeoutTimer.addEventListener(TimerEvent.TIMER_COMPLETE, onTimeout);
			}

			if (_urlStream != null)
			{
				_timeoutInterval = timeout;
				_request = request;
				CONFIG::LOGGING
				{
					logger.debug("Loading (timeout=" + _timeoutInterval + ", retry=" + _currentRetry + "):" + _request.url.toString());
				}
				_downloadBeginDate = null;
				_downloadBytesCount = 0;
				startTimeoutMonitor(_timeoutInterval);
				_urlStream.load(_request);
			}

			// Dispatch an event so any listeners can get a reference to us.
			_dispatcher.dispatchEvent(new HTTPStreamingEvent("dispatcherStart", false, false, 0, null, "", request.url.toString(), 0, "", this));
		}

		/**
		 * Takes an extra parameter for the target segment duration to setup the _segmentTimeoutTimer, then calls open()
		 */
		public function openWithSegmentTimeout(request:URLRequest, dispatcher:IEventDispatcher, 
												timeout:Number, targetSegmentDuration:Number):void
		{

			if (_segmentTimeoutTimer == null && targetSegmentDuration != -1)
			{
				// Sets the timer to targetSegmentDuration * multiplier specified - default is 2
				_segmentTimeoutTimer = new Timer(targetSegmentDuration 
												 * 1000 // convert to ms for timer
												 * HLSManifestParser.SEGMENT_TIMEOUT_MULTIPLIER, 1)
				_segmentTimeoutTimer.addEventListener(TimerEvent.TIMER_COMPLETE, onSegmentTimeout);
			}
			if (_segmentTimeoutTimer != null)
			{
				_segmentTimeoutTimer.reset();
				_segmentTimeoutTimer.start();
			}

			open(request, dispatcher, timeout);
		}
		
		/**
		 * Closes the HTTP stream source. It closes any open connection
		 * and also clears any buffered data.
		 * 
		 * @param dispose Flag to indicate if the underlying objects should 
		 * 				  also be disposed. Defaults to <code>false</code>
		 * 				  as is recommended to reuse these objects. 
		 **/ 
		public override function close(dispose:Boolean = false):void
		{
			if( _request && _request.url ){
				debugToJS( _request.url.toString(), "closed");
			}
			
			CONFIG::LOGGING
			{
				if (_request != null)
				{
					logger.debug("Closing :" + _request.url.toString());
				}
			}
			
			stopTimeoutMonitor();

			_isOpen = false;
			_isComplete = false;
			_hasData = false;
			_hasErrors = false;
			_request = null;
			
			if (_timeoutTimer != null)
			{
				_timeoutTimer.stop();
				if (dispose)
				{
					_timeoutTimer.removeEventListener(TimerEvent.TIMER_COMPLETE, onTimeout);
					_timeoutTimer = null;
				}
			}
			if (_segmentTimeoutTimer != null)
			{
				_segmentTimeoutTimer.stop();
				if (dispose)
				{
					_segmentTimeoutTimer.removeEventListener(TimerEvent.TIMER_COMPLETE, onSegmentTimeout);
					_segmentTimeoutTimer = null;
				}
			}

			if (_urlStream != null)
			{
				if (_urlStream.connected)
				{
					_urlStream.close();
				}
				if (dispose)
				{
					_urlStream.removeEventListener(Event.OPEN, onOpen);
					_urlStream.removeEventListener(Event.COMPLETE, onComplete);
					_urlStream.removeEventListener(ProgressEvent.PROGRESS, onProgress);
					_urlStream.removeEventListener(IOErrorEvent.IO_ERROR, onError);
					_urlStream.removeEventListener(SecurityErrorEvent.SECURITY_ERROR, onError);
					_urlStream = null;
				}
			}

			if (_savedBytes != null)
			{
				_savedBytes.length = 0;
				if (dispose)
				{
					_savedBytes = null;
				}
			}
		}
		
		/**
		 * Return the total number of available bytes,
		 * includes both saved bytes and bytes in the underlying url stream
		 **/
		public override function get totalAvailableBytes():int
		{
			if (!isOpen)
			{
				return 0;
			}
			else
			{
				return _savedBytes.bytesAvailable + _urlStream.bytesAvailable;
			}
		}
		
		/**
		 * Returns a buffer containing a specified number of bytes or null if 
		 * there are not enough bytes available.
		 * 
		 * @param numBytes The number of the bytes to be returned. 
		 **/
		public override function getBytes(numBytes:int = 0):IDataInput
		{
			if ( !isOpen || numBytes < 0)
			{
				return null;
			}
			
			if (numBytes == 0)
			{
				numBytes = 1;
			}
			
			var totalAvailableBytes:int = this.totalAvailableBytes;
			if (totalAvailableBytes == 0)
			{
				_hasData = false;
			}
			
			if (totalAvailableBytes < numBytes)
			{
				return null;
			}
			
			// use first the previous saved bytes and complete as needed
			// with bytes from the actual stream.
			if (_savedBytes.bytesAvailable)
			{
				var needed:int = numBytes - _savedBytes.bytesAvailable;
				if (needed > 0)
				{
					_urlStream.readBytes(_savedBytes, _savedBytes.length, needed);
				}
				
				return _savedBytes;
			}
			
			// make sure that the saved bytes buffer is empty 
			// and return the actual stream.
			_savedBytes.length = 0;
			return _urlStream;
		}
		
		/**
		 * Clears the saved bytes.
		 **/
		public override function clearSavedBytes():void
		{
			if(_savedBytes == null)
			{
				// called after dispose
				return;
			}
			_savedBytes.length = 0;
			_savedBytes.position = 0;
		}
		
		/**
		 * Copies the specified number of bytes from source into the saved bytes.
		 **/
		public override function appendToSavedBytes(source:IDataInput, count:uint):void
		{
			if(_savedBytes == null)
			{
				// called after dispose
				return;
			}
			source.readBytes(_savedBytes, _savedBytes.length, count);
		}
		
		/**
		 * Saves all remaining bytes from the HTTP stream source to
		 * internal buffer to be available in the future.
		 **/
		public override function saveRemainingBytes():void
		{
			if(_savedBytes == null)
			{
				// called after dispose
				return;
			}
			if (_urlStream != null && _urlStream.connected && _urlStream.bytesAvailable)
			{
				_urlStream.readBytes(_savedBytes, _savedBytes.length);
			}
			else
			{
				// no remaining bytes
			}
		}
		
		/**
		 * Returns a string representation of this object.
		 **/
		public override function toString():String
		{
			// TODO : add request url to this string
			return "HTTPStreamSource";
		}
		
		/// Event handlers
		/**
		 * @private
		 * Called when the connection has been open.
		 **/
		private function onOpen(event:Event):void
		{
			_isOpen = true;
			debugToJS( _request.url.toString(), "opened");
		}
		
		/**
		 * @private
		 * Called when all data has been downloaded.
		 **/
		private function onComplete(event:Event):void
		{
			debugToJS( _request.url.toString(), "complete");

			if (_downloadBeginDate == null)
			{
				_downloadBeginDate = new Date();
			}
			
			_downloadEndDate = new Date();

			if (_segmentTimeoutTimer != null)
			{
				_segmentTimeoutTimer.stop();
			}
			// We inexplicably see reversal of times in some cases. So maybe just cap to be positive duration.
			_downloadDuration = Math.abs(_downloadEndDate.valueOf() - _downloadBeginDate.valueOf())/1000.0;
			
			_isComplete = true;
			_hasErrors = false;
			
			CONFIG::LOGGING
			{
				logger.debug("Loading complete. It took " + _downloadDuration + " sec and " + _currentRetry + " retries to download " + _downloadBytesCount + " bytes.");	
			}
			
			if (_dispatcher != null)
			{
				var streamingEvent:HTTPStreamingEvent = new HTTPStreamingEvent(
					HTTPStreamingEvent.DOWNLOAD_COMPLETE,
					false, // bubbles
					false, // cancelable
					0, // fragment duration
					null, // scriptDataObject
					FLVTagScriptDataMode.NORMAL, // scriptDataMode
					_request.url, // urlString
					_downloadBytesCount, // bytesDownloaded
					HTTPStreamingEventReason.NORMAL, // reason
					this); // downloader
				_dispatcher.dispatchEvent(streamingEvent);
			}
		}
		
		private var _localStartTime:int = 0;
		private var _currentDownloadRate:Number = NaN;

		/**
		 * @private
		 * Called when additional data has been received.
		 **/
		private function onProgress(event:ProgressEvent):void
		{
			if (_downloadBeginDate == null)
			{
				_downloadBeginDate = new Date();
				_localStartTime = getTimer();
				_currentDownloadRate = NaN;
				if (_segmentTimeoutTimer != null) 
				{
					// checks if the _segmentTimeoutTimer exists, and restarts it at the beginning of a new download
					_segmentTimeoutTimer.reset();
					_segmentTimeoutTimer.start();
				}
			}
			
			if (_downloadBytesCount == 0)
			{
				if (_timeoutTimer != null)
				{
					stopTimeoutMonitor();
				}
				_currentRetry = 0;
			}

			_downloadBytesCount = event.bytesTotal;

			// Calculate speed so far.
			var currentDuration:Number = (getTimer() - _localStartTime) / 1000;
			if(currentDuration > 1.0 || event.bytesLoaded > event.bytesTotal * 0.25)
			{
				// Only update once we've gone for a little while or made some progress to avoid singularities.
				_currentDownloadRate = (event.bytesLoaded / currentDuration);
			}

			CONFIG::LOGGING
			{
				logger.debug("Loaded " + event.bytesLoaded + " bytes from " + _downloadBytesCount + " bytes @ " + _currentDownloadRate + " bytes/sec");
			}

			_hasData = true;			
			
			if(_dispatcher != null)
			{
				var streamingEvent:HTTPStreamingEvent = new HTTPStreamingEvent(
					HTTPStreamingEvent.DOWNLOAD_PROGRESS,
					false, // bubbles
					false, // cancelable
					0, // fragment duration
					null, // scriptDataObject
					FLVTagScriptDataMode.NORMAL, // scriptDataMode
					_request.url, // urlString
					0, // bytesDownloaded
					HTTPStreamingEventReason.NORMAL, // reason
					this); // downloader
				_dispatcher.dispatchEvent(streamingEvent);
			}
		}	
		
		/**
		 * @private
		 * Called when an error occurred while downloading.
		 **/
		private function onError(event:Event):void
		{
			debugToJS( _request.url.toString(), "error");

			if (_timeoutTimer != null)
			{
				stopTimeoutMonitor();
			}

			if (_segmentTimeoutTimer != null)
			{
				_segmentTimeoutTimer.stop();
				_segmentTimeoutTimer.reset();
			}
			
			if (_downloadBeginDate == null)
			{
				_downloadBeginDate = new Date();
			}
			_downloadEndDate = new Date();
			_downloadDuration = (_downloadEndDate.valueOf() - _downloadBeginDate.valueOf()) / 1000.0;
			
			_isComplete = false;
			_hasErrors = true;
			
			CONFIG::LOGGING
			{
				logger.error("Loading failed. It took " + _downloadDuration + " sec and " + _currentRetry + " retries to fail while downloading [" + _request.url + "].");
				logger.error("URLStream error event: " + event);
			}
			
			if (_dispatcher != null)
			{
				var reason:String = HTTPStreamingEventReason.NORMAL;
				if(event.type == Event.CANCEL)
				{
					reason = HTTPStreamingEventReason.TIMEOUT;
				}
				var requestURL:String = _request ? _request.url : "[no request]"; //added "[no request]" string notification for HLS error handler
				
				var streamingEvent:HTTPStreamingEvent = new HTTPStreamingEvent(
					HTTPStreamingEvent.DOWNLOAD_ERROR,
					false, // bubbles
					false, // cancelable
					0, // fragment duration
					null, // scriptDataObject
					FLVTagScriptDataMode.NORMAL, // scriptDataMode
					_request ? _request.url : "[no request]", // urlString
					0, // bytesDownloaded
					reason, // reason
					this); // downloader
				_dispatcher.dispatchEvent(streamingEvent);
			}
		}
		
		/**
		 * @private
		 * Starts the timeout monitor.
		 */
		private function startTimeoutMonitor(timeout:Number):void
		{
			if (_timeoutTimer != null)
			{
				if (timeout > 0)
				{
					_timeoutTimer.delay = timeout;
				}
				_timeoutTimer.reset();
				_timeoutTimer.start();
			}
		}
		
		/**
		 * @private
		 * Stops the timeout monitor.
		 */
		private function stopTimeoutMonitor():void
		{
			if (_timeoutTimer != null)
			{
				_timeoutTimer.stop();
			}
		}
		
		/**
		 * @private
		 * Event handler called when no data was received but the timeout interval passed.
		 */ 
		private function onTimeout(event:TimerEvent):void
		{
			debugToJS( _request.url.toString(), "timeout");

			CONFIG::LOGGING
			{
				logger.error("Timeout while trying to download [" + _request.url + "]");
				logger.error("Canceling and retrying the download.");
			}
			
			if (OSMFSettings.hdsMaximumRetries > -1)
			{
				_currentRetry++;
			}
			
			if (	
				OSMFSettings.hdsMaximumRetries == -1 
				||  (OSMFSettings.hdsMaximumRetries != -1 && _currentRetry < OSMFSettings.hdsMaximumRetries)
			)
			{					
				open(_request, _dispatcher, _timeoutInterval + OSMFSettings.hdsTimeoutAdjustmentOnRetry);
			}
			else
			{
				close();
				onError(new Event(Event.CANCEL));
			}
		}

		/**
		 * Triggered when the _segmentTimeoutTimer alerts it - closes the stream and triggers the SEGMENT_TIMEOUT event
		 */
		private function onSegmentTimeout(event:TimerEvent):void
		{
			trace("segmentTimeout has been triggered - closing the stream and dispatching the SEGMENT_TIMEOUT event");
			close();
			_dispatcher.dispatchEvent(new Event(SEGMENT_TIMEOUT, false, false));
		}
		
		/// Internals
		private var _isOpen:Boolean = false;
		private var _isComplete:Boolean = false;
		private var _hasData:Boolean = false;
		private var _hasErrors:Boolean = false;
		private var _savedBytes:ByteArray = null;
		private var _urlStream:URLStream = null;
		private var _request:URLRequest = null;
		private var _dispatcher:IEventDispatcher = null;
		
		private var _downloadBeginDate:Date = null;
		private var _downloadEndDate:Date = null;
		private var _downloadDuration:Number = 0;
		private var _downloadBytesCount:Number = 0;
		
		private var _timeoutTimer:Timer = null;
		private var _timeoutInterval:Number = 1000;
		private var _currentRetry:Number = 0;
		private var _segmentTimeoutTimer:Timer = null;
		
		public static const SEGMENT_TIMEOUT:String = "segment.timeout"; // event for when a segment times out

		CONFIG::LOGGING
		{
			private static const logger:org.osmf.logging.Logger = org.osmf.logging.Log.getLogger("org.osmf.net.httpstreaming.HLSHTTPStreamDownloader");
		}
	}
}
