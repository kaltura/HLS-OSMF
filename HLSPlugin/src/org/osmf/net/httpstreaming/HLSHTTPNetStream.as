/*****************************************************
 *  
 *  Copyright 2009 Adobe Systems Incorporated.  All Rights Reserved.
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
 *  Portions created by Adobe Systems Incorporated are Copyright (C) 2009 Adobe Systems 
 *  Incorporated. All Rights Reserved. 
 *  
 *****************************************************/
package org.osmf.net.httpstreaming
{
	import com.kaltura.hls.HLSIndexHandler;
	import com.kaltura.hls.HLSStreamingResource;
	import com.kaltura.hls.URLErrorRecoveryStates;
	import com.kaltura.hls.manifest.HLSManifestPlaylist;
	import com.kaltura.hls.manifest.HLSManifestSegment;
	import com.kaltura.hls.manifest.HLSManifestStream;
	import com.kaltura.hls.manifest.HLSManifestParser;
	
	import flash.events.NetStatusEvent;
	import flash.events.TimerEvent;
	import flash.net.NetConnection;
	import flash.net.NetStream;
	import flash.net.NetStreamPlayOptions;
	import flash.net.NetStreamPlayTransitions;
	import flash.utils.ByteArray;
	import flash.utils.Timer;
	import flash.utils.getTimer;
	
	import org.osmf.events.DVRStreamInfoEvent;
	import org.osmf.events.HTTPStreamingEvent;
	import org.osmf.events.QoSInfoEvent;
	import org.osmf.media.MediaResourceBase;
	import org.osmf.media.URLResource;
	import org.osmf.net.DynamicStreamingResource;
	import org.osmf.net.NetClient;
	import org.osmf.net.NetStreamCodes;
	import org.osmf.net.NetStreamPlaybackDetailsRecorder;
	import org.osmf.net.StreamType;
	import org.osmf.net.StreamingURLResource;
	import org.osmf.net.httpstreaming.dvr.DVRInfo;
	import org.osmf.net.httpstreaming.flv.FLVHeader;
	import org.osmf.net.httpstreaming.flv.FLVParser;
	import org.osmf.net.httpstreaming.flv.FLVTag;
	import org.osmf.net.httpstreaming.flv.FLVTagAudio;
	import org.osmf.net.httpstreaming.flv.FLVTagScriptDataMode;
	import org.osmf.net.httpstreaming.flv.FLVTagScriptDataObject;
	import org.osmf.net.httpstreaming.flv.FLVTagVideo;
	import org.osmf.net.qos.FragmentDetails;
	import org.osmf.net.qos.PlaybackDetails;
	import org.osmf.net.qos.QoSInfo;
	import org.osmf.net.qos.QualityLevel;
	import org.osmf.utils.OSMFSettings;
	
	CONFIG::LOGGING 
	{	
		import org.osmf.logging.Log;
		import org.osmf.logging.Logger;
	}
	
	CONFIG::FLASH_10_1	
	{
		import flash.net.NetStreamAppendBytesAction;
		import flash.events.DRMErrorEvent;
		import flash.events.DRMStatusEvent;
	}
	
	[ExcludeClass]
	
	[Event(name="DVRStreamInfo", type="org.osmf.events.DVRStreamInfoEvent")]
	
	[Event(name="runAlgorithm", type="org.osmf.events.HTTPStreamingEvent")]
	
	[Event(name="qosUpdate", type="org.osmf.events.QoSInfoEvent")]
	
	/**
	 * HLSHTTPNetStream is a duplicate of the OSMF HTTPNetStream class,  
	 * which can accept input via the appendBytes method.  In general, 
	 * the assumption is that a large media file is broken up into a 
	 * number of smaller fragments.
	 * 
	 * We use a duplicate of the class instead of extending the original
	 * because the original is completely closed and private, and unable
	 * to be properly extended to override the desired functionality.
	 * By duplicating it, we can modify the alternate audio stream
	 * data instantiation to suit our needs; specifically, the
	 * changeAudioStreamTo() method.
	 * 
	 * The org.osmf.net.httpstreaming namespace is required due to
	 * internal namespace usage.
	 */	
	public class HLSHTTPNetStream extends NetStream
	{
		CONFIG::LOGGING
		{
			private static var logger:Logger = Log.getLogger("org.osmf.net.httpstreaming.HLSHTTPNetStream");
			private var previouslyLoggedState:String = null;
		}

		// If enabled, we log to a FLV buffer that can be saved out via FileReference.
		// The testplayer does this.
		public static var writeToMasterBuffer:Boolean = false;
		public static var _masterBuffer:ByteArray = new ByteArray();

		private var neverPlayed:Boolean = true;
		private var neverBuffered:Boolean = true; // Set after first buffering event.
		private var bufferBias:Number = 0.0; // Used to forcibly add more time to the buffer based on other logic.

		// Explicit buffer management
		private var pendingTags:Vector.<FLVTag> = new Vector.<FLVTag>;
		private var bufferFeedMin:Number = 1.0; // How many seconds to actually keep fed into the native buffer.
		private var bufferFeedAmount:Number = 0.1; // How many seconds of data to feed when we feed.
		private var scanningForIFrame:Boolean = false; // When true, we are scanning video tags until we hit a keyframe/I-frame.
		private var scanningForIFrame_avcc:FLVTagVideo; // Holds the AVCC for the I-frame we are finding; used to splice stream.
		private var bufferParser:FLVParser = new FLVParser(false); // Used to parse incoming FLV stream to buffer. TODO: Refactor to be unnecessary.
		private var needPendingSort:Boolean = false; // Set when we detect a new tag that's not after the last one, to save on resorts.
		private var endAfterPending:Boolean = false;
		public var lastWrittenTime:Number = NaN; // The timestamp of the FLV tag we last wrote into the NetStream in seconds.

		// Operations on buffer
		/**
			State/Logic
				isBackInTime = if (lastTime - newTime) > 100ms
				scanningForIFrame

				if isBackInTime then
					scanningForIFrame = true

				if scanningForIFrame && !iFrame then
					skip it

				if scanningForIFrame && iFrame then
					scanningForIFrame = false
					splice and add IFrame, resume adding as normal

			Questions
				Do I splice audio or just add to end?
					Can we just sync with video?
				Do I splice script or just add to end?
				Is it a bad idea to maintain a single vector for this? 
					Will we hate splice/trim?
					We could LL but not needed till we see perf #s

			Append tag
				if new tag goes back in time...
				find the first i-frame in the new section at or after buffered tags
				splice at that point

			Feed buffer
				If >= min in buffer, return
				add tags until bufferfeedamount added
				trim buffer

			Flush? - not needed?
				We resync on iframe so we'll catch up anyway. 
				I-frame sync is an instant decision so we don't have to reset state
		
			To hook up:
				line 1156 - processAndAppend loop
				line 2224 - attemptAppendBytes
					- Accept everything here
					- check to push on every append?
					- filter if needed

				Need to flush internal buffer when on seek/reset appendBytesAction

			Concerns:
				Now potentially running three layers of parsing
					Can we couple things a bit more directly to minimize re-parsing?
					probably, but we can do it "raw" first to get it going
				Do we even need enhanced seeking?
					yes - this allows us to seek through P frames to a specific time.

		*/

		/**
		 * Constructor.
		 * 
		 * @param connection The NetConnection to use.
		 * @param indexHandler Object which exposes the index, which maps
		 * playback times to media file fragments.
		 * @param fileHandler Object which canunmarshal the data from a
		 * media file fragment so that it can be fed to the NetStream as
		 * TCMessages.
		 *  
		 *  @langversion 3.0
		 *  @playerversion Flash 10
		 *  @playerversion AIR 1.5
		 *  @productversion OSMF 1.0
		 */
		public function HLSHTTPNetStream( connection:NetConnection, factory:HTTPStreamingFactory, resource:URLResource = null)
		{
			super(connection);
			_resource = resource;
			_factory = factory;
			
			addEventListener(DVRStreamInfoEvent.DVRSTREAMINFO, 			onDVRStreamInfo);
			addEventListener(HTTPStreamingEvent.SCRIPT_DATA, 			onScriptData);
			addEventListener(HTTPStreamingEvent.BEGIN_FRAGMENT, 		onBeginFragment);
			addEventListener(HTTPStreamingEvent.END_FRAGMENT, 			onEndFragment);
			addEventListener(HTTPStreamingEvent.TRANSITION, 			onTransition);
			addEventListener(HTTPStreamingEvent.TRANSITION_COMPLETE, 	onTransitionComplete);
			addEventListener(HTTPStreamingEvent.ACTION_NEEDED, 			onActionNeeded);
			addEventListener(HTTPStreamingEvent.DOWNLOAD_ERROR,			onDownloadError);
			
			addEventListener(HTTPStreamingEvent.DOWNLOAD_COMPLETE,		onDownloadComplete);
			
			addEventListener(NetStatusEvent.NET_STATUS, onNetStatus, false, HIGH_PRIORITY, true);
			
			CONFIG::FLASH_10_1
			{
				addEventListener(DRMErrorEvent.DRM_ERROR, onDRMError);
				addEventListener(DRMStatusEvent.DRM_STATUS, onDRMStatus);
			}
				
			this.bufferTime = bufferFeedMin;
			this.bufferTimeMax = 0;
			
			setState(HTTPStreamingState.INIT);
			
			createSource(resource);
			
			_mainTimer = new Timer(OSMFSettings.hdsMainTimerInterval); 
			_mainTimer.addEventListener(TimerEvent.TIMER, onMainTimer);	
		}
		
		///////////////////////////////////////////////////////////////////////
		/// Public API overrides
		///////////////////////////////////////////////////////////////////////
		
		override public function set client(object:Object):void
		{
			super.client = object;
			
			if (client is NetClient && _resource is DynamicStreamingResource)
			{
				playbackDetailsRecorder = new NetStreamPlaybackDetailsRecorder(this, client as NetClient, _resource as DynamicStreamingResource);
			}
		}
		
		/**
		 * Plays the specified stream with respect to provided arguments.
		 */
		override public function play(...args):void 
		{			
			processPlayParameters(args);
			CONFIG::LOGGING
			{
				logger.debug("Play initiated for [" + _playStreamName +"] with parameters ( start = " + _playStart.toString() + ", duration = " + _playForDuration.toString() +" ).");
			}
			
			// Signal to the base class that we're entering Data Generation Mode.
			super.play(null);
			
			// Before we feed any messages to the Flash Player, we must feed
			// an FLV header first.
			var header:FLVHeader = new FLVHeader();
			var headerBytes:ByteArray = new ByteArray();
			header.write(headerBytes);
			if(writeToMasterBuffer)
			{
				trace("RESETTING MASTER BUFFER DUE TO PLAY");
				_masterBuffer.length = 0;
				_masterBuffer.position = 0;
				_masterBuffer.writeBytes(headerBytes);
			}
			appendBytes(headerBytes);
			
			// Initialize ourselves.
			_mainTimer.start();
			_initialTime = NaN;
			_lastValidTimeTime = 0;
			_seekTime = 0;
			_isPlaying = true;
			_isPaused = false;
			
			_notifyPlayStartPending = true;
			_notifyPlayUnpublishPending = false;
			
			changeSourceTo(_playStreamName, _playStart);
		}
		
		/**
		 * Pauses playback.
		 */
		override public function pause():void 
		{
			_isPaused = true;
			super.pause();
		}
		
		/**
		 * Resumes playback.
		 */
		override public function resume():void 
		{
			_isPaused = false;
			super.resume();

			// Always seek on live streams.
			if(_dvrInfo && indexHandler && indexHandler.manifest && (indexHandler.manifest.streamEnds == false))
			{
				CONFIG::LOGGING
				{
					logger.info("Resuming live stream at " + time);
				}
				seek(time);
			}

		}
		
		/**
		 * Plays the specified stream and supports dynamic switching and alternate audio streams. 
		 */
		override public function play2(param:NetStreamPlayOptions):void
		{
			_lastValidTimeTime = 0;

			// See if any of our alternative audio sources (if we have any) are marked as DEFAULT if this is our initial play
			if (!hasStarted)
			{
				checkDefaultAudio();
				hasStarted = true;
			}
			
			switch(param.transition)
			{
				case NetStreamPlayTransitions.RESET:
					play(param.streamName, param.start, param.len);
					break;
				
				case NetStreamPlayTransitions.SWITCH:
					changeQualityLevelTo(param.streamName);
					break;
				
				case NetStreamPlayTransitions.SWAP:
					changeAudioStreamTo(param.streamName);
					break;
				
				default:
					// Not sure which other modes we should add support for.
					super.play2(param);
			}
		} 
		
		/**
		 * Seeks into the media stream for the specified offset in seconds.
		 */
		override public function seek(offset:Number):void
		{
			// we can't seek before the playback starts or if it has stopped.
			if (_state != HTTPStreamingState.INIT)
			{
				_seekTarget = convertWindowTimeToAbsoluteTime(offset);

				CONFIG::LOGGING
				{
					logger.info("Setting seek (B) to " + _seekTarget + " based on passed value " + offset);
				}				
				
				setState(HTTPStreamingState.SEEK);
				
				dispatchEvent(
					new NetStatusEvent(
						NetStatusEvent.NET_STATUS, 
						false, 
						false, 
						{
							code:NetStreamCodes.NETSTREAM_SEEK_START, 
							level:"status"
						}
					)
				);		
			}
			
			_notifyPlayUnpublishPending = false;
		}
		
		/**
		 * Closes the NetStream object.
		 */
		override public function close():void
		{
			if (_videoHandler != null)
			{
				_videoHandler.close();
			}
			if (_mixer != null)
			{
				_mixer.close();
			}
			
			_mainTimer.stop();
			notifyPlayStop();
			
			setState(HTTPStreamingState.HALT);
			
			super.close();
		}

		protected function calculateTargetBufferTime():Number
		{
			// Are we in short-buffer mode?
			if(neverBuffered)
				return HLSManifestParser.INITIAL_BUFFER_THRESHOLD;

			// Ok - in normal buffering. Calculate initial value.
			return HLSManifestParser.NORMAL_BUFFER_THRESHOLD + bufferBias;
		}

		/**
		 * Calculate and set the proper bufferTime based on various factors.
		 */
		public function updateBufferTime():void
		{
			var targetBuffer:Number = calculateTargetBufferTime();

			// Apply some sanity logic: check that we don't try to buffer for longer than the video.
			if(indexHandler && _state != HTTPStreamingState.HALT)
			{
				var lastMan:HLSManifestParser = indexHandler.getLastSequenceManifest();
				if(lastMan && lastMan.streamEnds && targetBuffer > lastMan.bestGuessWindowDuration)
					targetBuffer = lastMan.bestGuessWindowDuration - 1;
			}

			super.bufferTime = bufferFeedMin;
			_desiredBufferTime_Min = targetBuffer;
			_desiredBufferTime_Max = HLSManifestParser.MAX_BUFFER_AMOUNT + bufferBias;
		}
		
		/**
		 * We just ignore this in favor of updateBufferTime.
		 */
		override public function set bufferTime(value:Number):void
		{
			// We will drive this by our own methods (updateBufferTime).
			return;
		}
		
		public function get absoluteTime():Number
		{
			return super.time + _initialTime;
		}

		protected var _timeCache_LastUpdatedTimestamp:Number = NaN;
		protected var _timeCache_ExpirationPeriod:Number = 5000;
		protected var _timeCache_liveEdge:Number = 0.0;
		protected var _timeCache_liveEdgeMinusWindowDuration:Number = NaN;

		/**
		 * @inheritDoc
		 */
		override public function get time():Number
		{
			var startTime:int = getTimer();

			if(isNaN(_initialTime))
				return _lastValidTimeTime;

			// Do we need to expire the cache?
			if(getTimer() - _timeCache_LastUpdatedTimestamp > _timeCache_ExpirationPeriod)
				_timeCache_LastUpdatedTimestamp = NaN;

			// If cache invalid, repopulate it.
			if(isNaN(_timeCache_LastUpdatedTimestamp) && indexHandler)
			{
				CONFIG::LOGGING
				{
					logger.debug("Repopulating time cache.");
				}
				if(indexHandler.isLiveEdgeValid)
				{
					_timeCache_liveEdge = indexHandler.liveEdge;
					_timeCache_liveEdgeMinusWindowDuration = _timeCache_liveEdge - indexHandler.windowDuration;
				}
				else
				{
					_timeCache_liveEdge = 0;
					_timeCache_liveEdgeMinusWindowDuration = 0;
				}

				_timeCache_LastUpdatedTimestamp = getTimer();
			}

			// First determine our absolute time.
			var potentialNewTime:Number = super.time + _initialTime;

			// Take into account any cached live edge offset.
			if(_timeCache_liveEdge != Number.MAX_VALUE)
				potentialNewTime -= _timeCache_liveEdgeMinusWindowDuration;

			if(!isNaN(potentialNewTime))
				_lastValidTimeTime = potentialNewTime;

			return _lastValidTimeTime;
		}

		public function convertWindowTimeToAbsoluteTime(pubTime:Number):Number
		{
			// Deal with DVR window seeking.
			if(indexHandler)
			{
				if(indexHandler.liveEdge != Number.MAX_VALUE)
					pubTime += indexHandler.liveEdge - indexHandler.windowDuration;
				else
					pubTime -= indexHandler.streamStartAbsoluteTime;
			}

			return pubTime;
		}
		
		/**
		 * @inheritDoc
		 */
		override public function get bytesLoaded():uint
		{		
			return _bytesLoaded;
		}
		
		///////////////////////////////////////////////////////////////////////
		/// Custom public API - specific to HTTPNetStream 
		///////////////////////////////////////////////////////////////////////
		/**
		 * Get stream information from the associated information.
		 */ 
		public function DVRGetStreamInfo(streamName:Object):void
		{
			if (_source.isReady)
			{
				// TODO: should we re-trigger the event?
			}
			else
			{
				// TODO: should there be a guard to protect the case where isReady is not yet true BUT play has already been called, so we are in an
				// "initializing but not yet ready" state? This is only needed if the caller is liable to call DVRGetStreamInfo and then, before getting the
				// event back, go ahead and call play()
				_videoHandler.getDVRInfo(streamName);
			}
		}
		
		/**
		 * @return true if BestEffortFetch is enabled.
		 */
		public function get isBestEffortFetchEnabled():Boolean
		{
			return _source != null &&
				_source.isBestEffortFetchEnabled;
		}
		
		///////////////////////////////////////////////////////////////////////
		/// Internals
		///////////////////////////////////////////////////////////////////////
		
		/**
		 * @private
		 * 
		 * Saves the current state of the object and sets it to the value specified.
		 **/ 
		private function setState(value:String):void
		{
			_state = value;
			
			CONFIG::LOGGING
			{
				if (_state != previouslyLoggedState)
				{
					logger.debug("State = " + _state);
					previouslyLoggedState = _state;
				}

				// Hack for better playhead reporting.
				if(_state == "init")
					_lastValidTimeTime = 0;
			}
		}
		
		/**
		 * @private
		 * 
		 * Processes provided arguments to obtain the actual
		 * play parameters.
		 */
		private function processPlayParameters(args:Array):void
		{
			if (args.length < 1)
			{
				throw new Error("HTTPNetStream.play() requires at least one argument");
			}
			
			_playStreamName = args[0];
			
			_playStart = 0;
			if (args.length >= 2)
			{
				_playStart = Number(args[1]);
			}
			
			_playForDuration = -1;
			if (args.length >= 3)
			{
				_playForDuration = Number(args[2]);
			}
		}
		
		/**
		 * @private
		 * 
		 * Changes the main media source to specified stream name.
		 */
		private function changeSourceTo(streamName:String, seekTarget:Number):void
		{
			_initializeFLVParser = true;
			CONFIG::LOGGING
			{
				logger.debug("Changing source to " + streamName + " , " + seekTarget);
			}

			// Make sure we don't go past the buffer for the live edge.
			if(indexHandler && seekTarget > indexHandler.liveEdge)
			{
				CONFIG::LOGGING
				{
					logger.debug("Capping seek (source change) to the known-safe live edge (" + seekTarget + " < " + indexHandler.liveEdge + ").");
				}
				seekTarget = indexHandler.liveEdge;
			}

			_seekTarget = seekTarget;
			_videoHandler.open(streamName);
			setState(HTTPStreamingState.SEEK);
		}
		
		/**
		 * @private
		 * 
		 * Changes the quality of the main stream.
		 */
		private function changeQualityLevelTo(streamName:String):void
		{
			_qualityLevelNeedsChanging = true;
			_desiredQualityStreamName = streamName;
			
			if (_source.isReady 
				&& (_videoHandler != null && _videoHandler.streamName != _desiredQualityStreamName)
			)
			{
				CONFIG::LOGGING
				{
					logger.debug("Stream source is ready so we can initiate change quality to [" + _desiredQualityStreamName + "]");
				}
				_videoHandler.changeQualityLevel(_desiredQualityStreamName);
				_qualityLevelNeedsChanging = false;
				_desiredQualityStreamName = null;
			}
			
			_notifyPlayUnpublishPending = false;
		}
		
		/**
		 * @private
		 * 
		 * Checks if we have an alternate audio stream marked as default, and changes to that audio stream. If for some reason
		 * there are multiple audio streams marked as default a log will be made and only the first default stream will be chosen.
		 * If there are audio streams defined, but none are tagged as default, the first stream will be used.
		 */
		private function checkDefaultAudio():void
		{
			var currentResource:HLSStreamingResource = _resource as HLSStreamingResource;// Make sure our resource is the right type
			var foundDefault:Boolean = false;// If we have found a default audio source yet
			
			var i:int;
			for (i=0; i < currentResource.alternativeAudioStreamItems.length; i++)
			{
				// Get our the info for our current audio stream item and make sure it is the right type
				var currentInfo:HLSManifestPlaylist = currentResource.alternativeAudioStreamItems[i].info as HLSManifestPlaylist;
				
				// We loop through our audio stream items until we find one with the default tag checked
				if (!currentInfo.isDefault)
					continue;// If this isn't default, try the next item
				
				if (!foundDefault)
				{
					// If we haven't already found a default, change the audio stream
					changeAudioStreamTo(currentInfo.name);
					foundDefault = true;
				}
				else
				{
					// If more than one item is tagged as default, ignore it and make a note in the log
					CONFIG::LOGGING
					{
						logger.debug("More than one audio stream marked as default. Ignoring \"" + currentInfo.name + "\"");
					}
				}
			}
			// If we didn't find a default, and we have alternate audio sources available, just use the first one
			if (!foundDefault && currentResource.alternativeAudioStreamItems.length > 0)
			{
				var firstInfo:HLSManifestPlaylist = currentResource.alternativeAudioStreamItems[0].info as HLSManifestPlaylist;
				changeAudioStreamTo(firstInfo.name);
			}
		}
		
		/**
		 * @private
		 * 
		 * Changes audio track to load from an alternate track.
		 */
		private function changeAudioStreamTo(streamName:String):void
		{
			if (_mixer == null)
			{
				CONFIG::LOGGING
				{
					logger.warn("Invalid operation(changeAudioStreamTo) for legacy source. Should been a mixed source.");
				}
				
				_audioStreamNeedsChanging = false;
				_desiredAudioStreamName = null;
				return;
			}
			
			_audioStreamNeedsChanging = true;
			_desiredAudioStreamName = streamName;
			
			if (_videoHandler.isOpen
				&& (
					(_mixer.audio == null && _desiredAudioStreamName != null)	
					||  (_mixer.audio != null && _mixer.audio.streamName != _desiredAudioStreamName)
				)
			)
			{
				CONFIG::LOGGING
				{
					logger.debug("Initiating change of audio stream to [" + _desiredAudioStreamName + "]");
				}
				
				var audioResource:MediaResourceBase = createAudioResource(_resource, _desiredAudioStreamName);
				if (audioResource != null)
				{
					// audio handler is not dispatching events on the NetStream
					_mixer.audio = new HLSHTTPStreamSource(_factory, audioResource, _mixer);
					_mixer.audio.open(_desiredAudioStreamName);
				}
				else
				{
					_mixer.audio = null;
				}
				
				_audioStreamNeedsChanging = false;
				_desiredAudioStreamName = null;
			}
			
			_notifyPlayUnpublishPending = false;
		}
		
		protected function createAudioResource(resource:MediaResourceBase, streamName:String):MediaResourceBase
		{
			var hlsResource:HLSStreamingResource = resource as HLSStreamingResource;
			var playLists:Vector.<HLSManifestPlaylist> = hlsResource.manifest.playLists;
			
			for ( var i:int = 0; i < playLists.length; i++ )
				if ( playLists[ i ].name == streamName ) break;
			
			if ( i >= playLists.length )
			{
				CONFIG::LOGGING
				{
					logger.error( "AUDIO STREAM " + streamName + "NOT FOUND" );
				}
				return null;
			}
			
			var playList:HLSManifestPlaylist = playLists[ i ];
			var result:HLSStreamingResource = new HLSStreamingResource( playList.uri, playList.name, StreamType.DVR );
			result.manifest = playList.manifest;
			
			return result;
		}
		
		/**
		 * @private
		 * 
		 * Event handler for net status events. 
		 */
		private function onNetStatus(event:NetStatusEvent):void
		{
			CONFIG::LOGGING
			{
				logger.debug("NetStatus event:" + event.info.code);
			}
			
			switch(event.info.code)
			{
				case NetStreamCodes.NETSTREAM_BUFFER_EMPTY:

					// Only apply bias after our first buffering event.
					if(bufferBias < HLSManifestParser.BUFFER_EMPTY_MAX_INCREASE && _state != HTTPStreamingState.HALT && neverBuffered == false)
					{
						bufferBias += HLSManifestParser.BUFFER_EMPTY_BUMP;

						CONFIG::LOGGING
						{
							logger.debug("NetStream emptied out, increasing buffer time bias by " + HLSManifestParser.BUFFER_EMPTY_BUMP + " seconds to " + bufferBias);
						}
					}

					neverBuffered = false;
					emptyBufferInterruptionSinceLastQoSUpdate = true;
					_wasBufferEmptied = true;


					CONFIG::LOGGING
					{
						logger.debug("Received NETSTREAM_BUFFER_EMPTY. _wasBufferEmptied = "+_wasBufferEmptied+" bufferLength "+this.bufferLength);
					}

					if  (_state == HTTPStreamingState.HALT) 
					{
						if (_notifyPlayUnpublishPending)
						{
							notifyPlayUnpublish();
							_notifyPlayUnpublishPending = false; 
						}
					}
					break;
				
				case NetStreamCodes.NETSTREAM_BUFFER_FULL:
					_wasBufferEmptied = false;
					CONFIG::LOGGING
					{
						logger.debug("Received NETSTREAM_BUFFER_FULL. _wasBufferEmptied = "+_wasBufferEmptied+" bufferLength "+this.bufferLength);
					}
					break;
				
				case NetStreamCodes.NETSTREAM_BUFFER_FLUSH:
					_wasBufferEmptied = false;
					CONFIG::LOGGING
					{
						logger.debug("Received NETSTREAM_BUFFER_FLUSH. _wasBufferEmptied = "+_wasBufferEmptied+" bufferLength "+this.bufferLength);
					}
					break;
				
				case NetStreamCodes.NETSTREAM_PLAY_STREAMNOTFOUND:
					// if we have received a stream not found error
					// then we close all data
					close();
					break;
				
				case NetStreamCodes.NETSTREAM_SEEK_NOTIFY:
					if (! event.info.hasOwnProperty("sentFromHTTPNetStream") )
					{
						// we actually haven't finished seeking, so we stop the propagation of the event
						event.stopImmediatePropagation();
						
						CONFIG::LOGGING
						{
							logger.debug("Seek notify caught and stopped");
						}
					}					
					break;
			}
			
			CONFIG::FLASH_10_1
			{
				if( event.info.code == NetStreamCodes.NETSTREAM_DRM_UPDATE)
				{
					// if a DRM Update is needed, then we block further data processing
					// as reloading of current media will be required
					CONFIG::LOGGING
					{
						logger.debug("DRM library needs to be updated. Waiting until DRM state is updated."); 
					}
					_waitForDRM = true;
				}
			}

			// Make sure we update the buffer thresholds immediately.
			updateBufferTime();
		}
		
		CONFIG::FLASH_10_1
		{
			/**
			 * @private
			 * 
			 * We need to process DRM-related errors in order to prevent downloading
			 * of unplayable content. 
			 */ 
			private function onDRMError(event:DRMErrorEvent):void
			{
				CONFIG::LOGGING
				{
					logger.debug("Received an DRM error (" + event.toString() + ").");
					logger.debug("Entering waiting mode until DRM state is updated."); 
				}
				_waitForDRM = true;
				setState(HTTPStreamingState.WAIT);
			}
			
			private function onDRMStatus(event:DRMStatusEvent):void
			{
				if (event.voucher != null)
				{
					CONFIG::LOGGING
					{
						logger.debug("DRM state updated. We'll exit waiting mode once the buffer is consumed.");
					}
					_waitForDRM = false;
				}
			}
		}
		
		/**
		 * @private
		 * 
		 * We cycle through HTTPNetStream states and do chunk
		 * processing. 
		 */  
		private function onMainTimer(timerEvent:TimerEvent):void
		{
			// Trigger buffer update.
			updateBufferTime();

			// Feed buffer.
			keepBufferFed();

			// Check for seeking state.
			if (seeking && time != timeBeforeSeek && _state != HTTPStreamingState.HALT)
			{
				seeking = false;
				timeBeforeSeek = Number.NaN;
				
				CONFIG::LOGGING
				{
					logger.debug("Seek complete and time updated to: " + time + ". Dispatching HTTPNetStatusEvent.NET_STATUS - Seek.Notify");
				}
				
				dispatchEvent(
					new NetStatusEvent(
						NetStatusEvent.NET_STATUS, 
						false, 
						false, 
						{
							code:NetStreamCodes.NETSTREAM_SEEK_NOTIFY, 
							level:"status", 
							seekPoint:time,
							sentFromHTTPNetStream:true
						}
					)
				);
			}
			
			if (currentFPS > maxFPS)
			{
				maxFPS = currentFPS;
			}

			if(_state == HTTPStreamingState.WAIT || _state == HTTPStreamingState.PLAY)
			{
				bufferTime = 99999; // Sanity to ensure we never allow this to work. Also forces us to recalculate it.
			}

			switch(_state)
			{
				case HTTPStreamingState.INIT:
					// do nothing
					_lastValidTimeTime = 0;
					break;
				
				case HTTPStreamingState.WAIT:
					// if we are getting dry then go back into
					// active play mode and get more bytes 
					// from the stream provider
					if (!_waitForDRM && (this.bufferLength < _desiredBufferTime_Max || checkIfExtraBufferingNeeded()))
					{
						setState(HTTPStreamingState.PLAY);
					}
					
					// Reset a timer every time this code is reached. If this code is NOT reached for a significant amount of time, it means
					// we are attempting to stream a quality level that is too high for the current bandwidth, and should switch to the lowest
					// quality, as a precaution.
					if (!streamTooSlowTimer && false)
					{
						// If the timer doesn't yet exist, create it, setting the delay to twice the maximum desired buffer time
						streamTooSlowTimer = new Timer(_desiredBufferTime_Max * 2000);

						streamTooSlowTimer.addEventListener(TimerEvent.TIMER, 
							function(timerEvent:TimerEvent = null):void {
							try
							{
								// Check we have a valid stream to switch to.
								if(!(_resource as HLSStreamingResource))
									return;

								if((_resource as HLSStreamingResource).manifest == null)
									return;

								if((_resource as HLSStreamingResource).manifest.streams.length < 1)
									return;

								if(indexHandler == null)
									return;

								// Check that we have the current index handler.
								if(HLSHTTPNetStream.indexHandler != indexHandler)
								{
									CONFIG::LOGGING
									{
										logger.info("Old streamTooSlowTimer fired; killing.");
									}
									streamTooSlowTimer.stop();
									return;
								}

								// If this event is hit, set the quality level to the lowest available quality level
								var newStream:String = indexHandler.getQualityLevelStreamName(0);
								if(!newStream)
								{
									CONFIG::LOGGING
									{
										logger.error("streamTooSlowTimer failed to get stream name for quality level 0");
									}
									return;
								}

								CONFIG::LOGGING
								{
									logger.warn("Warning: Buffer Time of " + _desiredBufferTime_Max * 2 + " seconds exceeded. Switching to quality 0 " + newStream);
								}
								changeQualityLevelTo(newStream);
							}
							catch(e:Error)
							{
								CONFIG::LOGGING
								{
									logger.error("Failure when trying to handle streamTooSlowTimer event: " + e.toString());									
								}
							}
						});
					}

					if(streamTooSlowTimer)
					{
						streamTooSlowTimer.reset();
						streamTooSlowTimer.start();
					}
					
					break;
				
				case HTTPStreamingState.SEEK:
					// In seek mode we just forward the seek offset to 
					// the stream provider. The only problem is that
					// we may call seek before our stream provider is
					// able to fulfill our request - so we'll stay in seek
					// mode until the provider is ready.
					if (_source.isReady)
					{
						timeBeforeSeek = time;
						seeking = true;

						// cleaning up the previous seek info
						_flvParser = null;
						if (_enhancedSeekTags != null)
						{
							_enhancedSeekTags.length = 0;
							_enhancedSeekTags = null;
						}
						
						_enhancedSeekTarget = _seekTarget;

						if(indexHandler && indexHandler.bumpedTime)
						{
							CONFIG::LOGGING
							{
								logger.debug("INDEX HANDLER REQUESTED TIME BUMP to " + indexHandler.bumpedSeek);
							}
							_seekTarget = indexHandler.bumpedSeek;
							_enhancedSeekTarget = indexHandler.bumpedSeek;
							indexHandler.bumpedTime = false;
						}

						// Netstream seek in data generation mode only clears the buffer.
						// It does not matter what value you pass to it. However, netstream
						// apparently doesn't do that if the value given is larger than
						// (2^31 - 1) / 1000, which is max int signed divided by 1000 miliseconds
						// Therefore, we always seek to 0. This is a workaround for FM-1519
						super.seek(0);
						
						CONFIG::FLASH_10_1
						{
							CONFIG::LOGGING
							{
								logger.debug("Emitting RESET_SEEK due to initializing seek.");
							}

							appendBytesAction(NetStreamAppendBytesAction.RESET_SEEK);
							flushPendingTags();
						}

						_initialTime = NaN;

						_wasBufferEmptied = true;
						
						if (playbackDetailsRecorder != null)
						{
							if (playbackDetailsRecorder.playingIndex != lastTransitionIndex)
							{
								CONFIG::LOGGING
								{
									logger.debug("Seeking before the last transition completed. Inserting TRANSITION_COMPLETE message in stream.");
								}
									
								var info:Object = new Object();
								info.code = NetStreamCodes.NETSTREAM_PLAY_TRANSITION_COMPLETE;
								info.level = "status";
								info.details = lastTransitionStreamURL;
								
								var sdoTag:FLVTagScriptDataObject = new FLVTagScriptDataObject();
								sdoTag.objects = ["onPlayStatus", info];
								
								insertScriptDataTag(sdoTag);
							}
						}
						
						// We do not allow the user to seek to before the DVR window
						if (indexHandler && _seekTarget < indexHandler.lastKnownPlaylistStartTime && _seekTarget >= 0 && !isNaN(_seekTarget))
						{
							CONFIG::LOGGING
							{
								logger.debug("Attempting to seek outside of DVR window, seeking to last known playlist start time of " + indexHandler.lastKnownPlaylistStartTime);
							}
							_seekTarget = indexHandler.lastKnownPlaylistStartTime;
						}
						
						// Handle a case where seeking to the end of a VOD causes the replay function to break
						var HLSResource:HLSStreamingResource = _resource as HLSStreamingResource;
						if (HLSResource.manifest.streamEnds && _seekTarget == determinePlaylistLength())
							timeBeforeSeek = Number.NaN;// This forces the player to finish the seeking process
						
						_seekTime = -1;
						CONFIG::LOGGING
						{
							logger.info("Seeking to " + _seekTarget);
						}
						_source.seek(_seekTarget);
						setState(HTTPStreamingState.WAIT);
					}
					break;
				
				case HTTPStreamingState.PLAY:
					if (badManifestUrl)
					{
						cantLoadManifest(badManifestUrl);
						break;
					}

					if(neverPlayed && indexHandler && indexHandler.manifest && (indexHandler.manifest.streamEnds == false))
					{
						neverPlayed = false;
						_seekTarget = Number.MAX_VALUE;
						CONFIG::LOGGING
						{
							logger.debug("Triggered first time seek to live edge!");
						}
						setState(HTTPStreamingState.SEEK);
						break;
					}
					
					// start the recovery process if we need to recover and our buffer is getting too low
					if (recoveryDelayTimer.running && recoveryDelayTimer.currentCount >= 1)
					{
						if (hasGottenManifest)
						{
							recoveryDelayTimer.stop();
							seekToRecoverStream();
						}
						break;
					}
					
					if (_notifyPlayStartPending)
					{
						_notifyPlayStartPending = false;
						notifyPlayStart();
					}
					
					if (_qualityLevelNeedsChanging)
					{
						changeQualityLevelTo(_desiredQualityStreamName);
					}
					if (_audioStreamNeedsChanging)
					{
						changeAudioStreamTo(_desiredAudioStreamName);
					}
					var processed:int = 0;
					var keepProcessing:Boolean = true;
					
					while(keepProcessing)
					{
						var bytes:ByteArray = _source.getBytes();
						issueLivenessEventsIfNeeded();
						if (bytes != null)
						{
							processed += processAndAppend(bytes);	
						}
						
						if (
							    (_state != HTTPStreamingState.PLAY) 	// we are no longer in play mode
							 || (bytes == null) 						// or we don't have any additional data
							 || (processed >= OSMFSettings.hdsBytesProcessingLimit) 	// or we have processed enough data  
						)
						{
							keepProcessing = false;
						}
					}
					
					if (_state == HTTPStreamingState.PLAY)
					{
						if (processed > 0)
						{
							CONFIG::LOGGING
							{
								logger.debug("Processed " + processed + " bytes ( buffer = " + this.bufferLength + ", bufferTime = " + this.bufferTime+", wasBufferEmptied = "+_wasBufferEmptied+" )" ); 
							}
								
							gotBytes = true;
							
							// we can reset the recovery state if we are able to process some bytes and the time has changed since the last error
							if (time != lastErrorTime && recoveryStateNum == URLErrorRecoveryStates.NEXT_SEG_ATTEMPTED)
							{
								errorSurrenderTimer.reset();
								firstSeekForwardCount = -1;
								recoveryStateNum = URLErrorRecoveryStates.IDLE;
								recoveryDelayTimer.reset();
							}

							if (_waitForDRM)
							{
								setState(HTTPStreamingState.WAIT);
							}
							else if (checkIfExtraBufferingNeeded())
							{
								// special case to keep buffering.
								// see checkIfExtraBufferingNeeded.
							}
							else if (this.bufferLength > _desiredBufferTime_Max)
							{
								// if our buffer has grown big enough then go into wait
								// mode where we let the NetStream consume the buffered 
								// data
								setState(HTTPStreamingState.WAIT);
							}
						}
						else
						{
							// if we reached the end of stream then we need stop and
							// dispatch this event to all our clients.						
							if (_source.endOfStream)
							{
								super.bufferTime = 0.1;
								CONFIG::LOGGING
								{
									logger.debug("End of stream reached. Stopping."); 
								}
								setState(HTTPStreamingState.STOP);
							}
						}
					}
					break;
				
				case HTTPStreamingState.STOP:

					endAfterPending = true;

					setState(HTTPStreamingState.HALT);
					break;
				
				case HTTPStreamingState.HALT:
					// do nothing
					break;
			}
		}
		
		/**
		 * @private
		 * 
		 * There is a rare case in where we may need to perform extra buffering despite the
		 * values of bufferLength and bufferTime. See implementation for details.
		 * 
		 * @return true if we need to go into play state (or remain in play state). 
		 * 
		 **/
		private function checkIfExtraBufferingNeeded():Boolean
		{
			// There is a rare case where the player may have sent a BUFFER_EMPTY and
			// is waiting for bufferLength to grow "big enough" to play, and
			// bufferLength > bufferTime. To address this case, we must buffer
			// until we get a BUFFER_FULL event.
			
			if(!_wasBufferEmptied || // we're not waiting for a BUFFER_FULL
				!_isPlaying || // playback hasn't started yet
				_isPaused) // we're paused
			{
				// we're not in this case
				return false;
			}
			
			if(this.bufferLength > _desiredBufferTime_Max + 30)
			{
				// prevent infinite buffering. if we've buffered a lot more than
				// expected and we still haven't received a BUFFER_FULL, make sure
				// we don't keep buffering endlessly in order to prevent excessive
				// server-side load.
				return false;
			}
			
			CONFIG::LOGGING
			{
				logger.debug("Performing extra buffering because the player is probably stuck. bufferLength = "+this.bufferLength+" bufferTime = "+bufferTime);
			}
			return true;
		}
			
		/**
		 * @private
		 * 
		 * issue NetStatusEvent.NET_STATUS with NetStreamCodes.NETSTREAM_PLAY_LIVE_STALL or
		 * NetStreamCodes.NETSTREAM_PLAY_LIVE_RESUME if needed.
		 **/
		private function issueLivenessEventsIfNeeded():void
		{
			if(_source.isLiveStalled && _wasBufferEmptied) 
			{
				if(!_wasSourceLiveStalled)
				{
					CONFIG::LOGGING
					{
						logger.debug("stall");
					}			
					// remember when we first stalled.
					_wasSourceLiveStalled = true;
					_liveStallStartTime = new Date();
					_issuedLiveStallNetStatus = false;
				}
				// report the live stall if needed
				if(shouldIssueLiveStallNetStatus())
				{
					CONFIG::LOGGING
					{
						logger.debug("issue live stall");
					}			
					dispatchEvent( 
						new NetStatusEvent( 
							NetStatusEvent.NET_STATUS
							, false
							, false
							, {code:NetStreamCodes.NETSTREAM_PLAY_LIVE_STALL, level:"status"}
						)
					);
					_issuedLiveStallNetStatus = true;
				}
			}
			else
			{
				// source reports that live is not stalled
				if(_wasSourceLiveStalled && _issuedLiveStallNetStatus)
				{
					// we went from stalled to unstalled, issue a resume
					dispatchEvent( 
						new NetStatusEvent( 
							NetStatusEvent.NET_STATUS
							, false
							, false
							, {code:NetStreamCodes.NETSTREAM_PLAY_LIVE_RESUME, level:"status"}
						)
					);
				}
				_wasSourceLiveStalled = false;
			}
		}
		
		/**
		 * @private
		 * 
		 * helper for issueLivenessEventsIfNeeded
		 **/
		private function shouldIssueLiveStallNetStatus():Boolean
		{
			if(_issuedLiveStallNetStatus)
			{
				return false;  // we already issued a stall
			}
			if(!_wasBufferEmptied)
			{
				return false; // we still have some content to play
			}
			
			var liveStallTolerance:Number =
				(this.bufferLength + Math.max(OSMFSettings.hdsLiveStallTolerance, 0) + 1)*1000;
			var now:Date = new Date();
			if(now.valueOf() < _liveStallStartTime.valueOf() + liveStallTolerance)
			{
				// once we hit the live head, don't signal live stall event for at least a few seconds
				// in order to reduce the number of false positives. this accounts for the case
				// where we've caught up with live.
				return false;
			}
			
			return true;
		}

		/**
		 * @private
		 * 
		 * Event handler for all DVR related information events.
		 */
		private function onDVRStreamInfo(event:DVRStreamInfoEvent):void
		{
			_dvrInfo = event.info as DVRInfo;
		}
		
		/**
		 * @private
		 * 
		 * Also on fragment boundaries we usually start our own FLV parser
		 * object which is used to process script objects, to update our
		 * play head and to detect if we need to stop the playback.
		 */
		private function onBeginFragment(event:HTTPStreamingEvent):void
		{
			CONFIG::LOGGING
			{
				logger.debug("Detected begin fragment for stream [" + event.url + "].");
				logger.debug("Dropped frames=" + this.info.droppedFrames + ".");
			}			
			
			if (isNaN(_initialTime) || !isNaN(_enhancedSeekTarget) ||  _playForDuration >= 0)
			{
				if (_flvParser == null)
				{
					CONFIG::LOGGING
					{
						logger.debug("Initialize the FLV Parser ( _enhancedSeekTarget = " + _enhancedSeekTarget + ", initialTime = " + _initialTime + ", playForDuration = " + _playForDuration + " ).");
						if (_insertScriptDataTags != null)
						{
							CONFIG::LOGGING
							{
								logger.debug("Script tags available (" + _insertScriptDataTags.length + ") for processing." );	
							}
						}
					}
					
					if (!isNaN(_enhancedSeekTarget) || _playForDuration >= 0)
					{
						_flvParserIsSegmentStart = true;	
					}
					_flvParser = new FLVParser(false);
				}
				_flvParserDone = false;
			}
		}

		/**
		 * @private
		 * 
		 * Usually the end of fragment is processed by the associated switch
		 * manager as is a good place to decide if we need to switch up or down.
		 */
		private function onEndFragment(event:HTTPStreamingEvent):void
		{
			CONFIG::LOGGING
			{
				logger.debug("Reached end fragment for stream [" + event.url + "].");
			}
			
			if (_videoHandler == null)
			{
				return;
			}
			
			var date:Date = new Date();
			var machineTimestamp:Number = date.getTime();
			
			var sourceQoSInfo:HTTPStreamHandlerQoSInfo = _videoHandler.qosInfo;
			
			var availableQualityLevels:Vector.<QualityLevel> = null;
			var actualIndex:uint = 0;
			var lastFragmentDetails:FragmentDetails = null;
			
			if (sourceQoSInfo != null)
			{
				availableQualityLevels = sourceQoSInfo.availableQualityLevels;
				actualIndex = sourceQoSInfo.actualIndex;
				lastFragmentDetails = sourceQoSInfo.lastFragmentDetails;
			}
			
			
			var playbackDetailsRecord:Vector.<PlaybackDetails> = null;
			var currentIndex:int = -1;
			
			if (playbackDetailsRecorder != null)
			{
				playbackDetailsRecord = playbackDetailsRecorder.computeAndGetRecord();
				currentIndex = playbackDetailsRecorder.playingIndex;
			}
			
			var qosInfo:QoSInfo = new QoSInfo
				( machineTimestamp 
					, time
					, availableQualityLevels
					, currentIndex
					, actualIndex
					, lastFragmentDetails
					, maxFPS
					, playbackDetailsRecord
					, info
					, bufferLength
					, bufferTime
					, emptyBufferInterruptionSinceLastQoSUpdate
				);
			
			dispatchEvent(new QoSInfoEvent(QoSInfoEvent.QOS_UPDATE, false, false, qosInfo));
			
			// Reset the empty buffer interruption flag
			emptyBufferInterruptionSinceLastQoSUpdate = false;
			
			dispatchEvent(new HTTPStreamingEvent(HTTPStreamingEvent.RUN_ALGORITHM));
			
			_lastSegmentEnd = indexHandler ? indexHandler.getCurrentSegmentEnd() : 0.0;
		}

		private var _lastSegmentEnd:int = -1;
		
		/**
		 * @private
		 * 
		 * We notify the starting of the switch so that the associated switch manager
		 * correctly update its state. We do that by dispatching a NETSTREAM_PLAY_TRANSITION
		 * event.
		 */
		private function onTransition(event:HTTPStreamingEvent):void
		{
			if (_resource is DynamicStreamingResource)
			{
				lastTransitionIndex = (_resource as DynamicStreamingResource).indexFromName(event.url);
				lastTransitionStreamURL = event.url;
			}
			
			dispatchEvent( 
				new NetStatusEvent( 
					NetStatusEvent.NET_STATUS
					, false
					, false
					, {code:NetStreamCodes.NETSTREAM_PLAY_TRANSITION, level:"status", details:event.url}
				)
			);
		}
		
		/**
		 * @private
		 * 
		 * We notify the switch completition so that switch manager to correctly update 
		 * its state and dispatch any related event. We do that by inserting an 
		 * onPlayStatus data packet into the stream.
		 */
		private function onTransitionComplete(event:HTTPStreamingEvent):void
		{
			onActionNeeded(event);
			
			var info:Object = new Object();
			info.code = NetStreamCodes.NETSTREAM_PLAY_TRANSITION_COMPLETE;
			info.level = "status";
			info.details = event.url;
			
			var sdoTag:FLVTagScriptDataObject = new FLVTagScriptDataObject();
			sdoTag.objects = ["onPlayStatus", info];
			
			insertScriptDataTag(sdoTag);
		}
		
		/**
		 * @private
		 * 
		 * We received an download error event. We will attempt to recover the stream, then dispatch a NetStatusEvent with StreamNotFound
		 * error to notify all NetStream consumers and close the current NetStream.
		 */
		private function onDownloadError(event:HTTPStreamingEvent):void
		{
			// We map all URL errors to Play.StreamNotFound.
			// Attempt to recover from a URL Error
			if (gotBytes && errorSurrenderTimer.currentCount < recognizeBadStreamTime)
			{	
				if (recoveryDelayTimer.currentCount < 1 && recoveryDelayTimer.running)
					return;
				
				recoveryDelayTimer.reset();
				recoveryDelayTimer.delay = bufferLength * 1000 < reloadDelayTime ? reloadDelayTime : bufferLength * 1000;
				recoveryDelayTimer.start();
				
				// Process any quality level change requests.
				if(event.url == "[no request]")
				{
					// Stuff index handler down a quality level.
					CONFIG::LOGGING
					{
						logger.debug("TRYING BITRATE DOWNSHIFT");
					}

					_videoHandler.changeQualityLevel( (_videoHandler as HLSHTTPStreamSource)._streamNames[0] );

					// Never die due to bandwidth, just keep trying.
					if(errorSurrenderTimer.currentCount > 5)
						errorSurrenderTimer.reset();

					seekToRecoverStream();
					return;
				}


				attemptStreamRecovery();
				
				return;
			}
			
			dispatchEvent
			( new NetStatusEvent
				( NetStatusEvent.NET_STATUS
					, false
					, false
					, {code:NetStreamCodes.NETSTREAM_PLAY_STREAMNOTFOUND, level:"error", details:event.url}
				)
			);
		}
		
		private function attemptStreamRecovery():void
		{
			if (!errorSurrenderTimer.running)
				errorSurrenderTimer.start();

			// Switch to a backup stream if available
			if (currentStream)
			{
				CONFIG::LOGGING
				{
					logger.error("Marking manifest not gotten.");
				}
				hasGottenManifest = false;
				indexHandler.switchToBackup(currentStream);
			}
			else
				hasGottenManifest = true;
			
			if (hasGottenManifest && recoveryDelayTimer.currentCount >= 1)
				seekToRecoverStream();
		}
		
		/**
		 * @private
		 * 
		 * URL error recovery is done through the clever use of seeking
		 */
		private function seekToRecoverStream():void
		{
			// We only want to start seeking if we have gotten our backup manifest (or we don't have one)
			if (!hasGottenManifest)
				return;
			
			// We recover by forcing another reload attempt through seeking
			if (recoveryStateNum != URLErrorRecoveryStates.NEXT_SEG_ATTEMPTED && errorSurrenderTimer.currentCount < 10)
			{
				// We just try to reload the same place when we know we aren't just dealing with a bad segment AND we have been trying to recover for < 10 seconds
				recoveryStateNum = URLErrorRecoveryStates.SEG_BY_TIME_ATTEMPTED;
				seekToRetrySegment(time);
			}
			else
			{
				// Here we seek forward in the stream one segment at a time to try and find a good segment.
				seekToRetrySegment(time + calculateSeekTime());
			}
		}
		
		/**
		 * @private
		 * 
		 * Closes the stream with a stream not found error. Used after failing to get a new manifest multiple times in a row.
		 * 
		 * @param url The URL of the manifest that is failing to load.
		 */
		private function cantLoadManifest(url:String):void
		{
			dispatchEvent
			( new NetStatusEvent
				( NetStatusEvent.NET_STATUS
					, false
					, false
					, {code:NetStreamCodes.NETSTREAM_PLAY_STREAMNOTFOUND, level:"error", details:url}
				)
			);
		}
		
		private function onDownloadComplete(event:HTTPStreamingEvent):void
		{
			CONFIG::LOGGING
			{
				logger.debug("Download complete: " + event.url + " (" + event.bytesDownloaded + " bytes)"); 
			}
			_bytesLoaded += event.bytesDownloaded;
		}
		
		/**
		 * @private
		 * 
		 * We notify that the playback started only when we start loading the 
		 * actual bytes and not when the play command was issued. We do that by
		 * dispatching a NETSTREAM_PLAY_START NetStatusEvent.
		 */
		private function notifyPlayStart():void
		{
			dispatchEvent( 
				new NetStatusEvent( 
					NetStatusEvent.NET_STATUS
					, false
					, false
					, {code:NetStreamCodes.NETSTREAM_PLAY_START, level:"status"}
				)
			); 
		}
		
		/**
		 * @private
		 * 
		 * We notify that the playback stopped only when close method is invoked.
		 * We do that by dispatching a NETSTREAM_PLAY_STOP NetStatusEvent.
		 */
		private function notifyPlayStop():void
		{
			dispatchEvent(
				new NetStatusEvent( 
					NetStatusEvent.NET_STATUS
					, false
					, false
					, {code:NetStreamCodes.NETSTREAM_PLAY_STOP, level:"status"}
				)
			); 
		}
		
		/**
		 * @private
		 * 
		 * We dispatch NETSTREAM_PLAY_UNPUBLISH event when we are preparing
		 * to stop the HTTP processing.
		 */		
		private function notifyPlayUnpublish():void
		{
			dispatchEvent(
				new NetStatusEvent( 
					NetStatusEvent.NET_STATUS
					, false
					, false
					, {code:NetStreamCodes.NETSTREAM_PLAY_UNPUBLISH_NOTIFY, level:"status"}
				)
			);
		}
		
		/**
		 * @private
		 * 
		 * Inserts a script data object in a queue which will be processed 
		 * by the NetStream next time it will play.
		 */
		private function insertScriptDataTag(tag:FLVTagScriptDataObject, first:Boolean = false):void
		{
			if (!_insertScriptDataTags)
			{
				_insertScriptDataTags = new Vector.<FLVTagScriptDataObject>();
			}
			
			if (first)
			{
				_insertScriptDataTags.unshift(tag);	
			}
			else
			{
				_insertScriptDataTags.push(tag);
			}
		}
		
		/**
		 * @private
		 * 
		 * Consumes all script data tags from the queue. Returns the number of bytes
		 * 
		 */
		private function consumeAllScriptDataTags(timestamp:Number):int
		{
			var processed:int = 0;
			var index:int = 0;
			var bytes:ByteArray = null;
			var tag:FLVTagScriptDataObject = null;
			
			for (index = 0; index < _insertScriptDataTags.length; index++)
			{
				bytes = new ByteArray();
				tag = _insertScriptDataTags[index];
				
				if (tag != null)
				{
					tag.timestamp = timestamp;
					tag.write(bytes);
					attemptAppendBytes(bytes);
					processed += bytes.length;
				}
			}
			_insertScriptDataTags.length = 0;
			_insertScriptDataTags = null;			
			
			return processed;
		}
		
		/**
		 * @private
		 * 
		 * Processes and appends the provided bytes.
		 */
		private function processAndAppend(inBytes:ByteArray):uint
		{
			if (!inBytes || inBytes.length == 0)
			{
				return 0;
			}
			
			var bytes:ByteArray;
			var processed:uint = 0;
			
			if (_flvParser == null)
			{
				// pass through the initial bytes 
				bytes = inBytes;
			}
			else
			{
				// we need to parse the initial bytes
				_flvParserProcessed = 0;
				inBytes.position = 0;	
				_flvParser.parse(inBytes, true, onTag);
				processed += _flvParserProcessed;
				if(!_flvParserDone)
				{
					// the common parser has more work to do in-path
					return processed;
				}
				else
				{
					// the common parser is done, so flush whatever is left 
					// and then pass through the rest of the segment
					bytes = new ByteArray();
					_flvParser.flush(bytes);
					//logger.debug("Flushing " + bytes.length);
					_flvParser = null;	
				}
			}
			
			processed += bytes.length;
			if (_state != HTTPStreamingState.STOP)
			{
				attemptAppendBytes(bytes);

				if(bufferLength == 0 && processed > 4096)
				{
					CONFIG::LOGGING
					{
						logger.error("I think I should reset playback. Emitting RESET_SEEK.");
					}

					appendBytesAction(NetStreamAppendBytesAction.RESET_SEEK);
					_initialTime = NaN;
				}
			}

			
			return processed;
		}
		
		/**
		 * @private
		 * 
		 * Helper function that calls consumeAllScriptDataTags and also
		 * performs some logging
		 */
		private function doConsumeAllScriptDataTags(timestamp:uint):void
		{
			if (_insertScriptDataTags != null)
			{
				CONFIG::LOGGING
				{
					logger.debug("Consume all queued script data tags ( use timestamp = " + timestamp + " ).");
				}
				_flvParserProcessed += consumeAllScriptDataTags(timestamp);
			}
		}
		
		/**
		 * FLVTag from OSMF stores timestamps as unsigned ints.
		 *
		 * However, the FLV spec indicates they are S24 with an 8 bit extension.
		 *
		 * So we must convert from uint to int explicitly to get proper behavior.
		 */
		public static function wrapTagTimestampToFLVTimestamp(timestamp:uint):int
		{
			var timestampCastHelper:Number = timestamp;

			while(timestampCastHelper > int.MAX_VALUE)
				timestampCastHelper -= Number(uint.MAX_VALUE);

			while(timestampCastHelper < -int.MAX_VALUE)
				timestampCastHelper += Number(uint.MAX_VALUE);

			return timestampCastHelper;
		}

		/**
		 * @private
		 * 
		 * Method called by FLV parser object every time it detects another
		 * FLV tag inside the buffer it tries to parse.
		 */
		private function onTag(tag:FLVTag):Boolean
		{

			// Make sure we don't go past the live edge even if it changes while seeking.
			if(indexHandler && indexHandler.isLiveEdgeValid)
			{
				var liveEdgeValue:Number = indexHandler.liveEdge;
				//trace("Seeing live edge of " + liveEdgeValue);
				if(_seekTarget > liveEdgeValue || _enhancedSeekTarget > liveEdgeValue)
				{
					CONFIG::LOGGING
					{
						logger.warn("Capping seek (onTag) to the known-safe live edge (" + _seekTarget + " > " + liveEdgeValue + ", " + _enhancedSeekTarget + " > " + liveEdgeValue + ").");
					}
					_seekTarget = liveEdgeValue - 0.5;
					_enhancedSeekTarget = liveEdgeValue - 0.5;
					setState(HTTPStreamingState.SEEK);
				}
			}

			var realTimestamp:int = wrapTagTimestampToFLVTimestamp(tag.timestamp);
			var currentTime:Number = realTimestamp / 1000.0;

			if (isNaN(_initialTime))
				_initialTime = currentTime;

			CONFIG::LOGGING
			{
				logger.debug("Saw tag @ " + realTimestamp + " timestamp=" + tag.timestamp + " currentTime=" + currentTime + " _seekTime=" + _seekTime + " _enhancedSeekTarget="+ _enhancedSeekTarget + " dataSize=" + tag.dataSize);
			}

			if (!isNaN(_enhancedSeekTarget))
			{
				if (currentTime < _enhancedSeekTarget)
				{
					CONFIG::LOGGING
					{
						logger.debug("Skipping FLV tag @ " + currentTime + " until " + _enhancedSeekTarget);
					}

					if (_enhancedSeekTags == null)
					{
						_enhancedSeekTags = new Vector.<FLVTag>();
					}
					
					if (tag is FLVTagVideo)
					{                                  
						if (_flvParserIsSegmentStart)	
						{	
							// Generate client side seek tag.				
							var _muteTag:FLVTagVideo = new FLVTagVideo();
							_muteTag.timestamp = tag.timestamp; // may get overwritten, ok
							_muteTag.codecID = FLVTagVideo(tag).codecID; // same as in use
							_muteTag.frameType = FLVTagVideo.FRAME_TYPE_INFO;
							_muteTag.infoPacketValue = FLVTagVideo.INFO_PACKET_SEEK_START;
							
							// and start saving, with this as the first...
							_enhancedSeekTags.push(_muteTag);

							_flvParserIsSegmentStart = false;
							
						}	
						
						_enhancedSeekTags.push(tag);
					} 
					//else is a data tag, which we are simply saving for later, or a 
					//FLVTagAudio, which we discard unless is a configuration tag
					else if ((tag is FLVTagScriptDataObject) || 
						(tag is FLVTagAudio && FLVTagAudio(tag).isCodecConfiguration))						                                                                   
					{
						_enhancedSeekTags.push(tag);
					}
				}
				else
				{
					// We've reached the tag whose timestamp is greater
					// than _enhancedSeekTarget, so we can stop seeking.
					_enhancedSeekTarget = NaN;

					// Process any client side seek tags.
					if (_enhancedSeekTags != null && _enhancedSeekTags.length > 0)
					{
						// We do this dance to get the NetStream into a clean state. If we don't
						// do this, then we can get failed resume in some scenarios - ie, audio
						// but no picture.
						super.close();
						super.play(null);
						appendBytesAction(NetStreamAppendBytesAction.RESET_SEEK);
						
						_initialTime = NaN;

						var codecID:int;
						var haveSeenVideoTag:Boolean = false;
						
						// twiddle and dump
						for (i=0; i<_enhancedSeekTags.length; i++)
						{
							var vTag:FLVTag = _enhancedSeekTags[i];
							
							if (vTag.tagType == FLVTag.TAG_TYPE_VIDEO)
							{
								var vTagVideo:FLVTagVideo = vTag as FLVTagVideo;
								
								if (vTagVideo.codecID == FLVTagVideo.CODEC_ID_AVC && vTagVideo.avcPacketType == FLVTagVideo.AVC_PACKET_TYPE_NALU)
								{
									// for H.264 we need to move the timestamp forward but the composition time offset backwards to compensate
									var adjustment:int = wrapTagTimestampToFLVTimestamp(tag.timestamp) - wrapTagTimestampToFLVTimestamp(vTagVideo.timestamp); // how far we are adjusting
									var compTime:int = vTagVideo.avcCompositionTimeOffset;
									compTime -= adjustment; // do the adjustment
									vTagVideo.avcCompositionTimeOffset = compTime;	// save adjustment
								}
								
								codecID = vTagVideo.codecID;
								haveSeenVideoTag = true;
							}
							
							vTag.timestamp = tag.timestamp;
							
							bytes = new ByteArray();
							vTag.write(bytes);
							_flvParserProcessed += bytes.length;

							if(writeToMasterBuffer)
								_masterBuffer.writeBytes(bytes);
							appendBytes(bytes);
						}
						
						// Emit end of client seek tag if we started client seek.
						if (haveSeenVideoTag)
						{
							trace("Writing end-of-seek tag");
							var _unmuteTag:FLVTagVideo = new FLVTagVideo();
							_unmuteTag.timestamp = tag.timestamp;  // may get overwritten, ok
							_unmuteTag.codecID = codecID;
							_unmuteTag.frameType = FLVTagVideo.FRAME_TYPE_INFO;
							_unmuteTag.infoPacketValue = FLVTagVideo.INFO_PACKET_SEEK_END;
							bytes = new ByteArray();
							_unmuteTag.write(bytes);
							_flvParserProcessed += bytes.length;

							if(writeToMasterBuffer)
								_masterBuffer.writeBytes(bytes);
							appendBytes(bytes);
						}
						
						_enhancedSeekTags = null;

						// Update the last written time so we don't RESET_SEEK inappropriately.
						lastWrittenTime = wrapTagTimestampToFLVTimestamp(tag.timestamp) / 1000.0;

					}
					
					// and append this one
					bytes = new ByteArray();
					tag.write(bytes);
					_flvParserProcessed += bytes.length;

					attemptAppendBytes(bytes);
					
					_flvParserDone = true;
					return false;	// and end of parsing (caller must dump rest, unparsed)
				}
				
				return true;
			} // enhanced seek
			
			if(true)
			{

				var b:ByteArray = new ByteArray();
				tag.write(b);
				attemptAppendBytes(b);
				_flvParserDone = true;
				return false;
			}


			//------------------------------------------------
			//------------------------------------------------
			//------------------------------------------------

			var i:int;


			// Apply bump if present.
			if(indexHandler && indexHandler.bumpedTime 
				&& (_enhancedSeekTarget > indexHandler.bumpedSeek
					|| _seekTarget > indexHandler.bumpedSeek))
			{
				CONFIG::LOGGING
				{
					logger.debug("INDEX HANDLER REQUESTED TIME BUMP to " + indexHandler.bumpedSeek);
				}
				_seekTarget = indexHandler.bumpedSeek;
				_enhancedSeekTarget = indexHandler.bumpedSeek;
			}

			if(_enhancedSeekTarget == Number.MAX_VALUE)
			{
				CONFIG::LOGGING
				{
					logger.debug("Left over enhanced seek-to-end, aborting (_seekTarget=" + _seekTarget + ").");
				}
				_enhancedSeekTarget = NaN;
				_seekTarget = NaN;
			}

			if(indexHandler)
				indexHandler.bumpedTime = false;

			CONFIG::LOGGING
			{
				logger.debug("Saw tag @ " + realTimestamp + " timestamp=" + tag.timestamp + " currentTime=" + currentTime + " _seekTime=" + _seekTime + " _enhancedSeekTarget="+ _enhancedSeekTarget + " dataSize=" + tag.dataSize);
			}

			// Fix for http://bugs.adobe.com/jira/browse/FM-1544
			// We need to take into account that flv tags' timestamps are 32-bit unsigned ints
			// This means they will roll over, but the bootstrap times won't, since they are 64-bit unsigned ints
			/*while (currentTime < _initialTime)
			{
				// Add 2^32 (4,294,967,296) milliseconds to the currentTime
				// currentTime is in seconds so we divide that by 1000
				currentTime += 4294967.296;
			}*/
			
			if (_playForDuration >= 0)
			{
				if (_initialTime >= 0)	// until we know this, we don't know where to stop, and if we're enhanced-seeking then we need that logic to be what sets this up
				{
					if (currentTime > (_initialTime + _playForDuration))
					{

						setState(HTTPStreamingState.STOP);
						_flvParserDone = true;
						if (_seekTime < 0)
						{
							_seekTime = _playForDuration + _initialTime;	// FMS behavior... the time is always the final time, even if we seek to past it
							// XXX actually, FMS  actually lets exactly one frame though at that point and that's why the time gets to be what it is
							// XXX that we don't exactly mimic that is also why setting a duration of zero doesn't do what FMS does (plays exactly that one still frame)
						}
						return false;
					}
				}
			}
			
			if (!isNaN(_enhancedSeekTarget))
			{
				if (currentTime < _enhancedSeekTarget)
				{
					CONFIG::LOGGING
					{
						logger.debug("Skipping FLV tag @ " + currentTime + " until " + _enhancedSeekTarget);
					}
					if (_enhancedSeekTags == null)
					{
						_enhancedSeekTags = new Vector.<FLVTag>();
					}
					
					if (tag is FLVTagVideo)
					{                                  
						if (_flvParserIsSegmentStart)	
						{	
							// Generate client side seek tag.				
							var _muteTag:FLVTagVideo = new FLVTagVideo();
							_muteTag.timestamp = tag.timestamp; // may get overwritten, ok
							_muteTag.codecID = FLVTagVideo(tag).codecID; // same as in use
							_muteTag.frameType = FLVTagVideo.FRAME_TYPE_INFO;
							_muteTag.infoPacketValue = FLVTagVideo.INFO_PACKET_SEEK_START;
							
							// and start saving, with this as the first...
							_enhancedSeekTags.push(_muteTag);

							_flvParserIsSegmentStart = false;
							
						}	
						
						_enhancedSeekTags.push(tag);
					} 
					//else is a data tag, which we are simply saving for later, or a 
					//FLVTagAudio, which we discard unless is a configuration tag
					else if ((tag is FLVTagScriptDataObject) || 
						(tag is FLVTagAudio && FLVTagAudio(tag).isCodecConfiguration))						                                                                   
					{
						_enhancedSeekTags.push(tag);
					}
				}
				else
				{
					// We've reached the tag whose timestamp is greater
					// than _enhancedSeekTarget, so we can stop seeking.
					_enhancedSeekTarget = NaN;

					// Update _seekTime even though it's not used.
					if (_seekTime < 0)
						_seekTime = currentTime;

					// Update initial time with time of tag.
					if(isNaN(_initialTime))
						_initialTime = currentTime;

					// Process any client side seek tags.
					if (_enhancedSeekTags != null && _enhancedSeekTags.length > 0)
					{
						// We do this dance to get the NetStream into a clean state. If we don't
						// do this, then we can get failed resume in some scenarios - ie, audio
						// but no picture.
						super.close();
						super.play(null);
						appendBytesAction(NetStreamAppendBytesAction.RESET_SEEK);
						
						_initialTime = NaN;

						var codecID:int;
						var haveSeenVideoTag:Boolean = false;
						
						// twiddle and dump
						for (i=0; i<_enhancedSeekTags.length; i++)
						{
							var vTag:FLVTag = _enhancedSeekTags[i];
							
							if (vTag.tagType == FLVTag.TAG_TYPE_VIDEO)
							{
								var vTagVideo:FLVTagVideo = vTag as FLVTagVideo;
								
								if (vTagVideo.codecID == FLVTagVideo.CODEC_ID_AVC && vTagVideo.avcPacketType == FLVTagVideo.AVC_PACKET_TYPE_NALU)
								{
									// for H.264 we need to move the timestamp forward but the composition time offset backwards to compensate
									var adjustment:int = wrapTagTimestampToFLVTimestamp(tag.timestamp) - wrapTagTimestampToFLVTimestamp(vTagVideo.timestamp); // how far we are adjusting
									var compTime:int = vTagVideo.avcCompositionTimeOffset;
									compTime -= adjustment; // do the adjustment
									vTagVideo.avcCompositionTimeOffset = compTime;	// save adjustment
								}
								
								codecID = vTagVideo.codecID;
								haveSeenVideoTag = true;
							}
							
							vTag.timestamp = tag.timestamp;
							
							bytes = new ByteArray();
							vTag.write(bytes);
							_flvParserProcessed += bytes.length;

							if(writeToMasterBuffer)
								_masterBuffer.writeBytes(bytes);
							appendBytes(bytes);
						}
						
						// Emit end of client seek tag if we started client seek.
						if (haveSeenVideoTag)
						{
							trace("Writing end-of-seek tag");
							var _unmuteTag:FLVTagVideo = new FLVTagVideo();
							_unmuteTag.timestamp = tag.timestamp;  // may get overwritten, ok
							_unmuteTag.codecID = codecID;
							_unmuteTag.frameType = FLVTagVideo.FRAME_TYPE_INFO;
							_unmuteTag.infoPacketValue = FLVTagVideo.INFO_PACKET_SEEK_END;
							bytes = new ByteArray();
							_unmuteTag.write(bytes);
							_flvParserProcessed += bytes.length;

							if(writeToMasterBuffer)
								_masterBuffer.writeBytes(bytes);
							appendBytes(bytes);
						}
						
						_enhancedSeekTags = null;

						// Update the last written time so we don't RESET_SEEK inappropriately.
						lastWrittenTime = wrapTagTimestampToFLVTimestamp(tag.timestamp) / 1000.0;

						// We are safe to consume the script data tags now.
						doConsumeAllScriptDataTags(wrapTagTimestampToFLVTimestamp(tag.timestamp));

					}
					
					// and append this one
					bytes = new ByteArray();
					tag.write(bytes);
					_flvParserProcessed += bytes.length;

					// Need to keep _initialTime up to date and we return below.
					if (isNaN(_initialTime))
					{
						trace("Setting new _initialTime of " + currentTime);
						_initialTime = currentTime;
					}

					attemptAppendBytes(bytes);
					
					if (_playForDuration >= 0)
					{
						return true;	// need to continue seeing the tags, and can't shortcut because we're being dropped off mid-segment
					}
					_flvParserDone = true;
					return false;	// and end of parsing (caller must dump rest, unparsed)
				}
				
				return true;
			} // enhanced seek
			
			if (isNaN(_initialTime))
			{
				trace("Setting new _initialTime of " + currentTime);
				_initialTime = currentTime;
			}

			// Before appending the tag, trigger the consumption of all
			// the script data tags, with this tag's timestamp
			doConsumeAllScriptDataTags(tag.timestamp);
			
			// finally, pass this one on to appendBytes...
			var bytes:ByteArray = new ByteArray();
			tag.write(bytes);

			//logger.debug("[2] APPEND BYTES tag.timestamp=" + tag.timestamp + " length=" + bytes.length);
			attemptAppendBytes(bytes);
			_flvParserProcessed += bytes.length;
			
			// probably done seeing the tags, unless we are in playForDuration mode...
			if (_playForDuration >= 0)
			{
				// using fragment duration to let the parser start when we're getting close to the end 
				// of the play duration (FM-1440)
				if (_source.fragmentDuration >= 0 && _flvParserIsSegmentStart)
				{
					// if the segmentDuration has been reported, it is possible that we might be able to shortcut
					// but we need to be careful that this is the first tag of the segment, otherwise we don't know what duration means in relation to the tag timestamp
					
					_flvParserIsSegmentStart = false; // also used by enhanced seek, but not generally set/cleared for everyone. be careful.
					currentTime = (tag.timestamp / 1000.0);
					if (currentTime + _source.fragmentDuration >= (_initialTime + _playForDuration))
					{
						// it stops somewhere in this segment, so we need to keep seeing the tags
						return true;
					}
					else
					{
						// stop is past the end of this segment, can shortcut and stop seeing tags
						_flvParserDone = true;
						return false;
					}
				}
				else
				{
					return true;	// need to continue seeing the tags because either we don't have duration, or started mid-segment so don't know what duration means
				}
			}
			// else not in playForDuration mode...
			_flvParserDone = true;
			return false;
		}
		
		/**
		 * @private
		 * 
		 * Event handler invoked when we need to handle script data objects.
		 */
		private function onScriptData(event:HTTPStreamingEvent):void
		{
			if (event.scriptDataMode == null || event.scriptDataObject == null)
			{
				return;
			}
			
			CONFIG::LOGGING
			{
				logger.debug("onScriptData called with mode [" + event.scriptDataMode + "].");
			}
			
			switch (event.scriptDataMode)
			{
				case FLVTagScriptDataMode.NORMAL:
					insertScriptDataTag(event.scriptDataObject, false);
					break;
				
				case FLVTagScriptDataMode.FIRST:
					insertScriptDataTag(event.scriptDataObject, true);
					break;
				
				case FLVTagScriptDataMode.IMMEDIATE:
					if (client)
					{
						var methodName:* = event.scriptDataObject.objects[0];
						var methodParameters:* = event.scriptDataObject.objects[1];
						
						CONFIG::LOGGING
						{
							logger.debug(methodName + " invoked."); 
						}
						
						if (client.hasOwnProperty(methodName))
						{
							// XXX note that we can only support a single argument for immediate dispatch
							client[methodName](methodParameters);	
						}
					}
					break;
			}
		}
		
		/**
		 * @private
		 * 
		 * We need to do an append bytes action to reset internal state of the NetStream.
		 */
		private function onActionNeeded(event:HTTPStreamingEvent):void
		{
			// [FM-1387] we are appending this action only when we are 
			// dealing with late-binding audio streams
			if (_mixer != null)
			{	
				CONFIG::LOGGING
				{
					logger.debug("We need to appendBytesAction RESET_BEGIN in order to reset NetStream internal state");
				}
				
				appendBytesAction(NetStreamAppendBytesAction.RESET_BEGIN);
				
				_initialTime = NaN;

				// Before we feed any TCMessages to the Flash Player, we must feed
				// an FLV header first.
				var header:FLVHeader = new FLVHeader();
				var headerBytes:ByteArray = new ByteArray();
				header.write(headerBytes);
				if(writeToMasterBuffer)
				{
					trace("RESETTING MASTER BUFFER");
					_masterBuffer.length = 0;
					_masterBuffer.position = 0;
					_masterBuffer.writeBytes(headerBytes);
				}
				appendBytes(headerBytes);

				flushPendingTags();
				keepBufferFed();
			}
		}

		/**
		 * Pick next tag, taking into account we may have N tags at next timestamp
		 * with different info of different priority which may not be in correct
		 * priority order. 
		 */
		private function extractNextTagToWriteToBuffer(curTagOffset:int = 0):FLVTag
		{
			// Scan tags for current time and pick highest priority option. These
			// variable definitions are in the desired priority.
			var avccTag:FLVTagVideo = null;
			var iframeTag:FLVTagVideo = null;
			var videoTag:FLVTagVideo = null;
			var audioTag:FLVTagAudio = null;
			var genericTag:FLVTag = null;

			// We don't have to unwrap these times since we only care about equality.
			var leadTime:Number = pendingTags[curTagOffset].timestamp;
			for(var i:int=curTagOffset; i<pendingTags.length; i++)
			{
				// Scan forward through the tags with identical timestamp at start of the
				// queue, and note the first we encounter of each type.

				// If we stop seeing equal times, stop.
				if(pendingTags[i].timestamp != leadTime)
					break;

				// Classify it by priority.
				var pendingTag:FLVTag = pendingTags[i];
				if(pendingTag is FLVTagVideo)
				{
					if(isTagAVCC(pendingTag as FLVTagVideo))
					{
						if(!avccTag)
							avccTag = pendingTag as FLVTagVideo;
					}
					else if (isTagIFrame(pendingTag as FLVTagVideo))
					{
						if(!iframeTag)
							iframeTag = pendingTag as FLVTagVideo;
					}
					else if(!videoTag)
					{
						videoTag = pendingTag as FLVTagVideo;
					}
				}
				else if(pendingTag is FLVTagAudio)
				{
					if(!audioTag)
						audioTag = pendingTag as FLVTagAudio;
				}
				else
				{
					if(!genericTag)
						genericTag = pendingTag;
				}
			}

			// Determine pick based on priority.
			var pickedTag:FLVTag = null;
			if(avccTag)
				pickedTag = avccTag;
			else if(iframeTag)
				pickedTag = iframeTag;
			else if(videoTag)
				pickedTag = videoTag;
			else if(audioTag)
				pickedTag = audioTag;
			else
				pickedTag = genericTag;

			// No tags found - easy out!
			if(pickedTag == null)
				return null;

			// Reorder buffer if needed to allow efficient traversal. In most cases,
			// this will do nothing. But if we picked other than the first tag, it
			// will swap that tag with the first tag so it's skipped next time.
			for(var j:int=curTagOffset; j<pendingTags.length; j++)
			{
				if(pendingTags[j] != pickedTag)
					continue;

				pendingTags[j] = pendingTags[curTagOffset];
				pendingTags[curTagOffset] = pickedTag;
				break;
			}

			return pickedTag;
		}
	
		/**
		 * Write the next few tags to keep the required amount of data in the
		 * Flash decoder buffer. This pulls from pendingTags.
		 */
		private function keepBufferFed():void
		{
			// Check the actual amount of content present.
			if(super.bufferLength >= bufferFeedMin && !_wasBufferEmptied)
			{
				CONFIG::LOGGING
				{
					logger.debug("Saw super.bufferLength " + super.bufferLength + " < " + bufferFeedMin);
				}
				return;
			}

			// Sort as needed.
			ensurePendingSorted();

			updateBufferTime();

			// We want to keep the actual required buffer short so we don't stall with
			// tags still pending.
			super.bufferTime = bufferFeedMin;

			// Append tag bytes until we've hit our time buffer goal.
			var curTagOffset:int = 0;
			while((super.bufferLength <= (bufferFeedMin + bufferFeedAmount) 
				   || _wasBufferEmptied)
			      && (pendingTags.length - curTagOffset) > 0)
			{
				if(curTagOffset > 100 && _wasBufferEmptied)
				{
					CONFIG::LOGGING
					{
						logger.debug("Avoiding loading entire pending tag list when dealing with an empty buffer event scenario.");
					}
					break;
				}

				// Append some tags, using utility function to ensure we get tags
				// always in right priority order when they occur at same time.
				var tag:FLVTag = extractNextTagToWriteToBuffer(curTagOffset);
				curTagOffset++;

				var expectedSize:int = FLVTag.TAG_HEADER_BYTE_COUNT + tag.dataSize + FLVTag.PREV_TAG_BYTE_COUNT;
				var buffer:ByteArray = new ByteArray();
				buffer.length = expectedSize;
				tag.write(buffer);

				// Look for malformed tags.
				if(expectedSize != buffer.length)
				{
					CONFIG::LOGGING
					{
						logger.debug("SAW BAD PACKET, IGNORING?! Size mismatch: " + expectedSize + " != " + buffer.length);
					}
					continue;
				}

				var tagTimeSeconds:Number = wrapTagTimestampToFLVTimestamp(tag.timestamp) / 1000;

				// If it's more than 0.5 second jump ahead of current playhead, insert a RESET_SEEK so we won't stall forever.
				var tagDelta:Number = Math.abs(tagTimeSeconds - lastWrittenTime);

				if(tagDelta > (bufferFeedMin + bufferFeedAmount * 2) || isNaN(tagDelta))
				{
					// Don't do this for script tags, as they sometimes show up in weird orders.
					CONFIG::LOGGING
					{
						logger.debug("Inserting RESET_SEEK due to " + tagDelta + " being bigger than  " + (bufferFeedMin + bufferFeedAmount * 2));
					}
					appendBytesAction(NetStreamAppendBytesAction.RESET_SEEK);
				}

				lastWrittenTime = tagTimeSeconds;

				// Do writing.
				CONFIG::LOGGING
				{
					logger.debug("Writing tag " + buffer.length + " bytes @ " + lastWrittenTime + "sec type=" + tag.tagType + (isTagAVCC(tag as FLVTagVideo) ? " avcc" : "") + (isTagIFrame(tag as FLVTagVideo) ? " iframe" : ""));
				}

				if(writeToMasterBuffer)
					_masterBuffer.writeBytes(buffer);				
				appendBytes(buffer);
			}

			// Erase the consumed tags. Do it after to avoid costly array shifting.
			if(curTagOffset)
			{
				CONFIG::LOGGING
				{
					logger.debug("Submitted " + curTagOffset + " tags, " + (pendingTags.length - curTagOffset) + " left");
				}

				pendingTags.splice(0, curTagOffset);				
			}

			// If we're at the end of the stream, emit termination events.
			if(endAfterPending && pendingTags.length == 0)
			{
				CONFIG::LOGGING
				{
					logger.debug("FIRING STREAM END");
				}

				// For us, ending means ending the sequence, firing an onPlayStatus event,
				// and then really ending.	
				appendBytesAction(NetStreamAppendBytesAction.END_SEQUENCE);
				appendBytesAction(NetStreamAppendBytesAction.RESET_SEEK);

				var playCompleteInfo:Object = new Object();
				playCompleteInfo.code = NetStreamCodes.NETSTREAM_PLAY_COMPLETE;
				playCompleteInfo.level = "status";
				
				var playCompleteInfoSDOTag:FLVTagScriptDataObject = new FLVTagScriptDataObject();
				playCompleteInfoSDOTag.objects = ["onPlayStatus", playCompleteInfo];
				
				var tagBytes:ByteArray = new ByteArray();
				playCompleteInfoSDOTag.write(tagBytes);
				appendBytes(tagBytes);
				
				appendBytesAction(NetStreamAppendBytesAction.END_SEQUENCE);

				// And done ending.
				endAfterPending = false;

				// Also flush our other state.
				flushPendingTags();
			}
		}

		public override function get bufferLength():Number
		{
			if(pendingTags.length == 0)
				return super.bufferLength;

			ensurePendingSorted();

			// Get active range of pending tags. Since we keep them sorted this is easy.
			var minTime:Number = wrapTagTimestampToFLVTimestamp(pendingTags[0].timestamp) / 1000.0;
			var maxTime:Number = wrapTagTimestampToFLVTimestamp(pendingTags[pendingTags.length - 1].timestamp) / 1000.0;
			var len:Number = (maxTime - minTime) + super.bufferLength;
			//trace("CALCULATED LENGTH TO BE " + len + " (" + (maxTime/1000) + " , " + (minTime/1000) + ", " + super.bufferLength + ")");
			return len;
		}

		// Get last video tag's time.
		private function getHighestVideoTime():Number
		{
			//ensurePendingSorted();

			for(var i:int=pendingTags.length-1; i>=0; i--)
			{
				var vTag:FLVTagVideo = pendingTags[i] as FLVTagVideo;
				
				if(!vTag)
					continue;

				return wrapTagTimestampToFLVTimestamp(vTag.timestamp);
			}

			return NaN;
		}

		// Get last audio tag's time.
		private function getHighestAudioTime():Number
		{
			//ensurePendingSorted();

			for(var i:int=pendingTags.length-1; i>=0; i--)
			{
				var aTag:FLVTagAudio = pendingTags[i] as FLVTagAudio;
				
				if(!aTag)
					continue;

				return wrapTagTimestampToFLVTimestamp(aTag.timestamp);
			}

			return NaN;
		}

		public static function isTagAVCC(tag:FLVTagVideo):Boolean
		{
			if(!tag)
				return false;

			if(tag.codecID != FLVTagVideo.CODEC_ID_AVC)
				return false;

			// Must be keyframe.
			if(tag.frameType != FLVTagVideo.FRAME_TYPE_KEYFRAME)
				return false;

			// If config record, then it's an AVCC!
			return tag.avcPacketType == FLVTagVideo.AVC_PACKET_TYPE_SEQUENCE_HEADER;
		}


		public static function isTagIFrame(tag:FLVTagVideo):Boolean
		{
			if(!tag)
				return false;

			if(tag.codecID != FLVTagVideo.CODEC_ID_AVC)
				return false;

			// Must be keyframe.
			if(tag.frameType != FLVTagVideo.FRAME_TYPE_KEYFRAME)
				return false;

			// It's an I-frame if not a config record!
			return tag.avcPacketType == FLVTagVideo.AVC_PACKET_TYPE_NALU;
		}

		private function onBufferTag(tag:FLVTag):Boolean
		{
			var realTimestamp:int = wrapTagTimestampToFLVTimestamp(tag.timestamp);

			//trace("Got tag " + tag + " @ " + realTimestamp);

			// First, is it audio/video/other?
			if(tag is FLVTagAudio)
			{
				var highestAudioTime:Number = getHighestAudioTime();
				if(!isNaN(highestAudioTime) && realTimestamp < highestAudioTime)
				{
					CONFIG::LOGGING
					{
						logger.warn("Skipping audio due to too low time (" + realTimestamp + " < " + highestAudioTime + ")");
					}
					return true;
				}
			}
			else if (tag is FLVTagVideo)
			{
				var vTag:FLVTagVideo = tag as FLVTagVideo;

				var timeDelta:Number = getHighestVideoTime() - realTimestamp;
				var isBackInTime:Boolean = timeDelta > 150;
				var isIFrame:Boolean = isTagIFrame(vTag);

				//trace("was i-frame " + isIFrame + " was AVCC " + isTagAVCC(vTag));

				if(isNaN(timeDelta))
				{
					CONFIG::LOGGING
					{
						logger.debug("Suppressing potential I-frame scan due to no pre-existing video tags.");
					}

					timeDelta = 0;
					isBackInTime = false;
					scanningForIFrame = false;
				}

				if(!scanningForIFrame && isBackInTime)
				{
					CONFIG::LOGGING
					{
						logger.debug("   o I-FRAME SCAN due to backwards time (delta=" + timeDelta + ")");
					}
					
					scanningForIFrame = true;
				}

				// Skip totally implausible tags - we need to splice which means the splice must happen after
				// tags we have fed into the flash decoder.
				if(!scanningForIFrame && 
					pendingTags.length > 0 && realTimestamp < wrapTagTimestampToFLVTimestamp(pendingTags[0].timestamp))
				{
					scanningForIFrame = true;

					// Note for later use when we splice.
					if(isTagAVCC(vTag))
						scanningForIFrame_avcc = vTag;

					CONFIG::LOGGING
					{
						logger.debug("   - I-FRAME SCAN and reject due to impossible time (" + realTimestamp + " < " + wrapTagTimestampToFLVTimestamp(pendingTags[0].timestamp) + ")");
					}
					
					return true;
				}

				// Skip until we find our I-frame.
				if(scanningForIFrame && !isIFrame)
				{
					// Note latest AVCC for splicing.
					if(isTagAVCC(vTag))
						scanningForIFrame_avcc = vTag;

					CONFIG::LOGGING
					{
						logger.debug("   - SKIPPING non-I-FRAME");
					}
					
					return true;
				}

				if(scanningForIFrame && isIFrame)
				{
					CONFIG::LOGGING
					{
						logger.debug("   + GOT I-FRAME @ " + realTimestamp);
					}
					
					scanningForIFrame = false;

					// Make sure our tags are in order before splicing.
					ensurePendingSorted();

					// We want to splice our new video segment starting from the first i-frame
					// onto the old buffered content. So we go into the pending tags list and 
					// drop all the video tags that come after the I-frame we are inserting.
					for(var i:int=pendingTags.length-1; i>=0 && pendingTags.length > 0; i--)
					{
						// Extra sanity since we are mutating the list.
						if(i > pendingTags.length - 1)
							i = pendingTags.length - 1;
							
						// Consider every video tag. Audio is handled elsewhere.
						var potentialFilterTag:FLVTagVideo = pendingTags[i] as FLVTagVideo;
						if(!potentialFilterTag)
							continue;

						// Stop dropping frames once we find a video tag before the video tag we want to splice.
						if(wrapTagTimestampToFLVTimestamp(potentialFilterTag.timestamp) < realTimestamp)
							break;

						// Remove this tag, update i.
						CONFIG::LOGGING
						{
							logger.debug("   o removing tag at index " + i);
						}
						
						pendingTags.splice(i, 1);
						i++;
					}

					// Did we write the whole buffer? Then clue the decoder that we're probably jumping time.
					if(pendingTags.length == 0)
					{
						CONFIG::LOGGING
						{
							logger.debug("   o Emptied pending tags during I-frame scan, emitting RESET_SEEK!");
						}

						appendBytesAction(NetStreamAppendBytesAction.RESET_SEEK);
						_initialTime = realTimestamp / 1000;
					}

					// Insert the AVCC at the I-frame's timestamp.
					if(scanningForIFrame_avcc)
					{
						// We don't have to re-check sorting because this timestamp
						// is identical to the tag next to be added - so it will always
						// trip the sort check below.
						scanningForIFrame_avcc.timestamp = tag.timestamp;
						pendingTags.push(scanningForIFrame_avcc);
						scanningForIFrame_avcc = null;
					}
					else
					{
						CONFIG::LOGGING
						{
							logger.debug("   o Had no AVCC when splicing I-frame.");
						}
					}

					// Drop through to let tag be added.
				}
			}

			// Add to the queue, marking if we need to resort.
			if(!needPendingSort 
				&& pendingTags.length > 0 
				&& (wrapTagTimestampToFLVTimestamp(tag.timestamp) 
					- wrapTagTimestampToFLVTimestamp(pendingTags[pendingTags.length-1].timestamp)) <= 0)
			{
				needPendingSort = true;
			}

			pendingTags.push(tag);

			return true;
		}

		// Reset the pending buffer actions.
		private function flushPendingTags():void
		{
			CONFIG::LOGGING
			{
				logger.debug("FLUSHING PENDING TAGS");
			}
			
			pendingTags.length = 0;
			endAfterPending = false;
			needPendingSort = false;
			scanningForIFrame = false;
			lastWrittenTime = NaN;
		}

		static protected function pendingSortCallback(a:FLVTag, b:FLVTag):int
		{
			// We don't have to unwrap here because it's a subtractive comparison -
			// so wrapping works OK.
			const aTime:int = wrapTagTimestampToFLVTimestamp(a.timestamp);
			const bTime:int = wrapTagTimestampToFLVTimestamp(b.timestamp);

			return aTime - bTime;
		}

		private function ensurePendingSorted():void
		{
			if(needPendingSort == false)
				return;

			pendingTags.sort(pendingSortCallback);

			needPendingSort = false;
		}

		/**
		 * @private
		 * 
		 * Attempts to use the appendsBytes method. Do nothing if this is not compiled
		 * for an Argo player or newer.
		 */
		private function attemptAppendBytes(bytes:ByteArray, allowFeed:Boolean = true):void
		{
			//trace("Parsing " + bytes.length);

			// Parse to FLV tags and insert into queue.
			bytes.position = 0;
			bufferParser.parse(bytes, true, onBufferTag);

			//trace("    In buffer: " + pendingTags.length + " tags");

			// Feed Flash buffer if needed.
			if(allowFeed)
			{
				keepBufferFed();
			}
		}

		/**
		 * @private
		 * 
		 * Creates the source object which will be used to consume the associated resource.
		 */
		protected function createSource(resource:URLResource):void
		{
			var source:IHTTPStreamSource = null;
			var streamingResource:StreamingURLResource = resource as StreamingURLResource;
			if (streamingResource == null || streamingResource.alternativeAudioStreamItems == null || streamingResource.alternativeAudioStreamItems.length == 0)
			{
				// we are not in alternative audio scenario, we are going to the legacy mode
				var legacySource:IHTTPStreamSource = new HLSHTTPStreamSource(_factory, _resource, this);
				
				_source = legacySource;
				_videoHandler = legacySource as IHTTPStreamHandler;
			}
			else
			{
				_mixer = new HLSHTTPStreamMixer(this);
				_mixer.video = new HLSHTTPStreamSource(_factory, _resource, _mixer);
				
				_source = _mixer;
				_videoHandler = _mixer.video;
			}
		}
		
		/**
		 * @private
		 * 
		 * Seeks the video to a specific time and marks us as no longer waiting for an
		 * attempt to grab data. Only used when a previously good stream encounters a
		 * URL error. Will allow the player to pick up again if the URL error was
		 * a fluke.
		 * 
		 * @param requestedTime The time that the function will seek to
		 */
		private function seekToRetrySegment(requestedTime:Number):void
		{
			// If we are in a live stream, treat this scenario as a restart.
			if(indexHandler)
			{
				var lastMan:HLSManifestParser = indexHandler.getLastSequenceManifest();
				if(lastMan && lastMan.streamEnds == false && requestedTime < indexHandler.lastKnownPlaylistStartTime)
				{
					requestedTime = Number.MAX_VALUE;
				}
			}

			CONFIG::LOGGING
			{
				logger.debug("Seeking to retry segment " + requestedTime);
			}
			_seekTarget = requestedTime;
			setState(HTTPStreamingState.SEEK);
		}
		
		/**
		 * @private
		 * 
		 * Calculate how far we need to seek forward in case of a URL error that doesn't resolve
		 * in time.
		 * 
		 * @return The amount of time the player needs to seek forward
		 */
		private function calculateSeekTime():Number
		{	
			if (currentStream)
			{
				// If we have more than one stream, use the determined stream to find the segment index
				return getSeekTimeWithSegments(currentStream.manifest.segments);
			}
			else
			{
				// Otherwise, use the current resource (it should contain our segments)
				var HLSResource:HLSStreamingResource = _resource as HLSStreamingResource;
				return getSeekTimeWithSegments(HLSResource.manifest.segments);
			}
		}
		
		/**
		 * @private
		 * 
		 * Helps to determine how far forward to seek in the event of a continuing URL error
		 * 
		 * @param A vector that contains the segments of our current stream
		 */
		private function getSeekTimeWithSegments(seg:Vector.<HLSManifestSegment>):Number
		{
			var currentIndex:int = determineSegmentIndex();// the index of the segment we are currently playing
			var manifestLength:int = seg.length;// we will use this more than once
			
			// if we are currently at the last segment in the manifest or our time does not match any segments, do not seek forward
			if (currentIndex == manifestLength - 1 || currentIndex == - 1)
				return 0;
			
			// find the amount of time we need to seek forward
			// we want to try to download each segment a few times (if it fails at first), so the loop is tied in to the error timer which ticks once a second
			if (firstSeekForwardCount == -1)
				firstSeekForwardCount = errorSurrenderTimer.currentCount;
			var index:int = 0;
			var seekForwardTime:Number = seg[currentIndex].duration - (time - seg[currentIndex].startTime) + seekForwardBuffer;
			for (index = 1; index <= errorSurrenderTimer.currentCount - firstSeekForwardCount; index++)
			{
				// don't try to seek past the last segment
				if (currentIndex + index >= manifestLength - 1)
					return seekForwardTime;
				
				// add the duration of segments in order to get to the segment we are trying to seek to
				seekForwardTime += seg[currentIndex + index].duration;
			}
			return seekForwardTime;
		}
		
		/**
		 * @private
		 * 
		 * Determines the index of the segment we are currently playing
		 * 
		 * @return The index of the segment we are currently playing
		 */
		private function determineSegmentIndex():Number
		{
			if (currentStream)
			{
				// If we have more than one stream, use the determined stream to find the segment index
				return getSegmentIndexWithSegments(currentStream.manifest.segments);
			}
			else
			{
				// Otherwise, use the current resource (it should contain our segments)
				var HLSResource:HLSStreamingResource = _resource as HLSStreamingResource;
				return getSegmentIndexWithSegments(HLSResource.manifest.segments);
			}
		}
		
		/**
		 * @private
		 * 
		 * Helps to determine the segment we are currently playing and is used in case our playlist has a single stream.
		 * 
		 * @param seg The vector of segments we are attempting to find our current position in.
		 * @return The index of our current segment, or -1 if the current segment cannot be found.
		 */
		private function getSegmentIndexWithSegments(seg:Vector.<HLSManifestSegment>):int
		{
			for (var index:int = 0; index < seg.length; index++)
			{
				// if the current time in in between a segment's start time, and the segment's end time, we found the current segment
				if (seg[index].startTime <= time &&
					time < seg[index].startTime + seg[index].duration)
				{
					return index;
				}
			}
			// if our time does not match any available segments for some reason, return -1
			return -1;
		}
		
		/**
		 * @private
		 * 
		 * Determines the length (in seconds) of the playlist we are currently playing
		 */
		private function determinePlaylistLength():Number
		{
			if (currentStream)
			{
				// If we have more than one stream, use the last segment in the determined stream to find the stream length
				return getPLengthWithSegment(currentStream.manifest.segments[currentStream.manifest.segments.length - 1]);
			}
			else
			{
				// Otherwise, use the current resource (it should contain our segments)
				var HLSResource:HLSStreamingResource = _resource as HLSStreamingResource;
				return getPLengthWithSegment(HLSResource.manifest.segments[HLSResource.manifest.segments.length - 1]);
			}
		}
		
		/**
		 * @private
		 * 
		 * Helps to determine the length of the playlist we are currently playing
		 * 
		 * @param seg The last segment in the current playlist
		 */
		private function getPLengthWithSegment(seg:HLSManifestSegment):Number
		{
			return seg.startTime + seg.duration;
		}
			
		private var _desiredBufferTime_Min:Number = 0;
		private var _desiredBufferTime_Max:Number = 0;
		
		private var _mainTimer:Timer = null;
		private var _state:String = HTTPStreamingState.INIT;
		
		private var _playStreamName:String = null;
		private var _playStart:Number = -1;
		private var _playForDuration:Number = -1; 
		
		private var _resource:URLResource = null;
		private var _factory:HTTPStreamingFactory = null;
		
		private var _mixer:HLSHTTPStreamMixer = null;
		private var _videoHandler:IHTTPStreamHandler = null;
		private var _source:IHTTPStreamSource = null;
		
		private var _qualityLevelNeedsChanging:Boolean = false;
		private var _desiredQualityStreamName:String = null;
		private var _audioStreamNeedsChanging:Boolean = false;
		private var _desiredAudioStreamName:String = null;
		
		private var _seekTarget:Number = NaN;
		private var _enhancedSeekTarget:Number = NaN;
		private var _enhancedSeekTags:Vector.<FLVTag>;
		
		private var _notifyPlayStartPending:Boolean = false;
		private var _notifyPlayUnpublishPending:Boolean = false;
		
		private var _initialTime:Number = NaN;	// this is the timestamp derived at start-of-play (offset or not)... what FMS would call "0" - it is used to adjust super.time to be an absolute time
		private var _seekTime:Number = -1;		// this is the timestamp derived at end-of-seek (enhanced or not)... what we need to add to super.time (assuming play started at zero) - this guy is not used for anything much anymore
		private var _lastValidTimeTime:Number = 0; // this is the last known timestamp returned; used to avoid showing garbage times.
		
		private var _initializeFLVParser:Boolean = false;
		private var _flvParser:FLVParser = null;	// this is the new common FLVTag Parser
		private var _flvParserDone:Boolean = true;	// signals that common parser has done everything and can be removed from path
		private var _flvParserProcessed:uint;
		private var _flvParserIsSegmentStart:Boolean = false;
		
		private var _insertScriptDataTags:Vector.<FLVTagScriptDataObject> = null;
		
		private var _fileTimeAdjustment:Number = 0;	// this is what must be added (IN SECONDS) to the timestamps that come in FLVTags from the file handler to get to the index handler timescale
		// XXX an event to set the _fileTimestampAdjustment is needed
		
		private var _mediaFragmentDuration:Number = 0;
		
		private var _dvrInfo:DVRInfo = null;
		
		private var _waitForDRM:Boolean = false;
		
		private var maxFPS:Number = 0;
		
		private var playbackDetailsRecorder:NetStreamPlaybackDetailsRecorder = null;
		
		private var lastTransitionIndex:int = -1;
		private var lastTransitionStreamURL:String = null;
		
		private var lastTime:Number = Number.NaN;
		private var timeBeforeSeek:Number = Number.NaN;
		private var seeking:Boolean = false;
		private var emptyBufferInterruptionSinceLastQoSUpdate:Boolean = false;
		
		private var _bytesLoaded:uint = 0;
		
		private var _wasSourceLiveStalled:Boolean = false;
		private var _issuedLiveStallNetStatus:Boolean = false;
		private var _wasBufferEmptied:Boolean = false;	// true if the player is waiting for BUFFER_FULL.
		// this occurs when we receive a BUFFER_EMPTY or when we we're buffering
		// in response to a seek.
		private var _isPlaying:Boolean = false; // true if we're currently playing. see checkIfExtraKickNeeded
		private var _isPaused:Boolean = false; // true if we're currently paused. see checkIfExtraKickNeeded
		private var _liveStallStartTime:Date;
		
		private var hasStarted:Boolean = false;// true after we have played once, checked before automatically switching to a default stream
		
		private var retryAttemptCount:Number = 0;// this is how many times we have tried to recover from a URL error in a row. Used to assist in retry timing and scrubbing
		private var seekForwardBuffer:Number = 0.5;// this is how far ahead of the next segment we should seek to in order to ensure we load that segment
		private var lastErrorTime:Number = 0;// this is the last time there was an error. Used when determining if an error has been resolved
		private var firstSeekForwardCount:int = -1;// the count of errorSurrenderTimer when we first try to seek forward
		private var recoveryBufferMin:Number = 2;// how low the bufferTime can get in seconds before we start trying to recover a stream by seeking
		private var recoveryDelayTimer:Timer = new Timer(0); // timer that will be set to the required delay of reload attempts in the case of a URL error
		private var gotBytes:Boolean = false;// If we got bytes- marks a stream that we should attempt to recover
		
		private var streamTooSlowTimer:Timer;
		
		public static var currentStream:HLSManifestStream;// this is the manifest we are currently using. Used to determine how much to seek forward after a URL error
		public static var indexHandler:HLSIndexHandler;// a reference to the active index handler. Used to update the quality list after a change.
		public static var recognizeBadStreamTime:Number = 20;// this is how long in seconds we will attempt to recover after a URL error before we give up completely
		public static var badManifestUrl:String = null;// if this is not null we need to close down the stream
		public static var recoveryStateNum:int = URLErrorRecoveryStates.IDLE;// used when recovering from a URL error to determine if we need to quickly skip ahead due to a bad segment
		public static var errorSurrenderTimer:Timer = new Timer(1000);// Timer used by both this and HLSHTTPNetStream to determine if we should give up recovery of a URL error
		public static var hasGottenManifest:Boolean = false;
		public static var reloadDelayTime:int = 2500;// The amount of time (in miliseconds) we want to wait between reload attempts in case of a URL error
		
		private static const HIGH_PRIORITY:int = int.MAX_VALUE;
	}
}
