package com.kaltura.hls.m2ts
{
	import com.kaltura.hls.HLSIndexHandler;
	import com.kaltura.hls.HLSStreamingResource;
	import com.kaltura.hls.SubtitleTrait;
	import com.kaltura.hls.manifest.HLSManifestEncryptionKey;
	import com.kaltura.hls.muxing.AACParser;
	import com.kaltura.hls.subtitles.SubTitleParser;
	import com.kaltura.hls.subtitles.TextTrackCue;
	
	import flash.external.ExternalInterface;
	import flash.utils.ByteArray;
	import flash.utils.IDataInput;
	import flash.utils.getTimer;

	import flash.external.ExternalInterface;
	
	import org.osmf.events.HTTPStreamingEvent;
	import org.osmf.net.httpstreaming.HTTPStreamingFileHandlerBase;
	import org.osmf.net.httpstreaming.flv.FLVTagAudio;

	/**
	 * Process M2TS data into FLV data and return it for rendering via OSMF video system.
	 */
	public class M2TSFileHandler extends HTTPStreamingFileHandlerBase
	{
		public static var SEND_LOGS:Boolean = false;
		
		public var subtitleTrait:SubtitleTrait;
		public var key:HLSManifestEncryptionKey;
		public var segmentId:uint = 0;
		public var resource:HLSStreamingResource;
		public var segmentUri:String;
		public var isBestEffort:Boolean = false;
		
		private var _parser:TSPacketParser;
		private var _curTimeOffset:uint;
		private var _buffer:ByteArray;
		private var _fragReadBuffer:ByteArray;
		private var _encryptedDataBuffer:ByteArray;
		private var _timeOrigin:uint;
		private var _timeOriginNeeded:Boolean;
		private var _segmentBeginSeconds:Number;
		private var _segmentLastSeconds:Number;
		private var _firstSeekTime:Number;
		private var _lastContinuityToken:String;
		private var _extendedIndexHandler:IExtraIndexHandlerState;
		private var _lastFLVMessageTime:Number;
		private var _injectingSubtitles:Boolean = false;
		private var _lastInjectedSubtitleTime:Number = 0;
		
		private var _decryptionIV:ByteArray;
		
		public function M2TSFileHandler()
		{
			super();
			
			_encryptedDataBuffer = new ByteArray();

			_parser = new TSPacketParser();
			_parser.callback = handleFLVMessage;
			
			_timeOrigin = 0;
			_timeOriginNeeded = true;
			
			_segmentBeginSeconds = -1;
			_segmentLastSeconds = -1;
			
			_firstSeekTime = 0;
			
			_extendedIndexHandler = null;
			
			_lastContinuityToken = null;
		}

		public function get duration():Number
		{
			if(_segmentLastSeconds > _segmentBeginSeconds)
				return _segmentLastSeconds - _segmentBeginSeconds;
			return -1;
		}

		public function set extendedIndexHandler(handler:IExtraIndexHandlerState):void
		{
			_extendedIndexHandler = handler;
		}
		
		public function get extendedIndexHandler():IExtraIndexHandlerState
		{
			return _extendedIndexHandler;
		}
		
		public override function beginProcessFile(seek:Boolean, seekTime:Number):void
		{
			if(seek && !isBestEffort)
			{
				// Reset low water mark for the file handler so we don't drop stuff.
				trace("RESETTING LOW WATER MARK");
				clearFLVWaterMarkFilter();
			}

			if( key && !key.isLoading && !key.isLoaded)
				throw new Error("Tried to process segment with key not set to load or loaded.");

			if(isBestEffort)
			{
				trace("Doing extra flush for best effort file handler");
				_parser.flush();
				_parser.clear();
			}

			// Decryption reset
			if ( key )
			{
				trace("Resetting _decryptionIV");
				if ( key.iv ) _decryptionIV = key.retrieveStoredIV();
				else _decryptionIV = HLSManifestEncryptionKey.createIVFromID( segmentId );
			}
			
			var discontinuity:Boolean = false;
			
			if(_extendedIndexHandler)
			{
				var currentContinuityToken:String = _extendedIndexHandler.getCurrentContinuityToken();
				
				if(_lastContinuityToken != currentContinuityToken)
					discontinuity = true;
				_lastContinuityToken = currentContinuityToken;
			}
			
			if(seek)
			{
				_parser.clear();
				
				_timeOriginNeeded = true;
				
				if(_extendedIndexHandler)
					_firstSeekTime = _extendedIndexHandler.calculateFileOffsetForTime(seekTime) * 1000.0;
			}
			else if(discontinuity)
			{
				// Kick the converter state, but try to avoid upsetting the audio stream.
				_parser.clear(false);
				
				if(_segmentLastSeconds >= 0.0)
				{
					_timeOriginNeeded = true;
					if(_extendedIndexHandler)
						_firstSeekTime = _extendedIndexHandler.getCurrentSegmentOffset() * 1000.0;
					else
						_firstSeekTime = _segmentLastSeconds * 1000.0 + 30;
				}
			}
			else if(_extendedIndexHandler && _segmentLastSeconds >= 0.0)
			{
				var currentFileOffset:Number = _extendedIndexHandler.getCurrentSegmentOffset();
				var delta:Number = currentFileOffset - _segmentLastSeconds;

				// If it's a big jump, handle it.
				if(delta > 5.0)
				{
					_timeOriginNeeded = true;
					_firstSeekTime = currentFileOffset * 1000.0;
				}
			}
			
			_segmentBeginSeconds = -1;
			_segmentLastSeconds = -1;
			_lastInjectedSubtitleTime = -1;
			_encryptedDataBuffer.length = 0;

			// Note the start as a debug event.
			_parser.sendDebugEvent( {type:"segmentStart", uri:segmentUri});
		}
		
		public override function get inputBytesNeeded():Number
		{
			return 0;
		}

		public static var tmpBuffer:ByteArray = new ByteArray();

		private function basicProcessFileSegment(input:IDataInput, _flush:Boolean):ByteArray
		{
			if ( key && !key.isLoaded )
			{
				trace("basicProcessFileSegment - Waiting on key to download.");
				if(input)
					input.readBytes( _encryptedDataBuffer, _encryptedDataBuffer.length );
				return null;
			}
			
			tmpBuffer.position = 0;
			tmpBuffer.length = 0;
			
			if ( _encryptedDataBuffer.length > 0 )
			{
				// Restore any pending encrypted data.
				trace("Restoring " + _encryptedDataBuffer.length + " bytes of encrypted data.");
				_encryptedDataBuffer.position = 0;
				_encryptedDataBuffer.readBytes( tmpBuffer );
				_encryptedDataBuffer.clear();
			}

			if(!input)
				input = new ByteArray();
			
			var amountToRead:int = input.bytesAvailable;
			if(amountToRead > 1024*128) amountToRead = 1024*128;
			trace("READING " + amountToRead + " OF " + input.bytesAvailable);
			if(amountToRead > 0)
				input.readBytes( tmpBuffer, tmpBuffer.length, amountToRead);
			
			if ( key )
			{
				// We need to decrypt available data.
				var bytesToRead:uint = tmpBuffer.length;
				var leftoverBytes:uint = bytesToRead % 16;
				bytesToRead -= leftoverBytes;

				trace("Decrypting " + tmpBuffer.length + " bytes of encrypted data.");
				
				key.usePadding = false;
				
				if ( leftoverBytes > 0 )
				{
					// Place any bytes left over (not divisible by 16) into our encrypted buffer
					// to decrypt later, when we have more bytes
					tmpBuffer.position = bytesToRead;
					tmpBuffer.readBytes( _encryptedDataBuffer );
					tmpBuffer.length = bytesToRead;
					trace("Storing " + _encryptedDataBuffer.length + " bytes of encrypted data.");
				}
				else
				{
					// Attempt to unpad if our buffer is equally divisible by 16.
					// It could mean that we've reached the end of the file segment.
					key.usePadding = true;
				}
				
				// Store our current IV so we can use it do decrypt
				var currentIV:ByteArray = _decryptionIV;
				
				// Stash the IV for our next set of bytes - last block of the ciphertext.
				_decryptionIV = new ByteArray();
				tmpBuffer.position = bytesToRead - 16;
				tmpBuffer.readBytes( _decryptionIV );
				
				// Aaaaand... decrypt!
				tmpBuffer = key.decrypt( tmpBuffer, currentIV );
			}
			
			// If it's AAC, process it.
			if(AACParser.probe(tmpBuffer))
			{
				//trace("GOT AAC " + tmpBuffer.bytesAvailable);
				var aac:AACParser = new AACParser();
				aac.parse(tmpBuffer, _fragReadHandler);
				//trace("    - returned " + _fragReadBuffer.length + " bytes!");
				_fragReadBuffer.position = 0;

				if(isBestEffort && _fragReadBuffer.length > 0)
				{
					trace("Discarding AAC data from best effort.");
					_fragReadBuffer.length = 0;
				}

				return _fragReadBuffer;
			}
			
			// Parse it as MPEG TS data.
			var buffer:ByteArray = new ByteArray();
			_buffer = buffer;
			_parser.appendBytes(tmpBuffer);
			if ( _flush ) 
			{
				trace("flushing parser");
				_parser.flush();
			}
			_buffer = null;
			buffer.position = 0;

			// Throw it out if it's a best effort fetch.
			if(isBestEffort && buffer.length > 0)
			{
				trace("Discarding normal data from best effort.");
				buffer.length = 0;
			}

			if(buffer.length == 0)
				return null;

			return buffer;
		}
		
		private function _fragReadHandler(audioTags:Vector.<FLVTagAudio>, adif:ByteArray):void 
		{
			_fragReadBuffer = new ByteArray();
			var audioTag:FLVTagAudio = new FLVTagAudio();
			audioTag.soundFormat = FLVTagAudio.SOUND_FORMAT_AAC;
			audioTag.data = adif;
			audioTag.isAACSequenceHeader = true;
			audioTag.write(_fragReadBuffer);
			
			for(var i:int=0; i<audioTags.length; i++)
				audioTags[i].write(_fragReadBuffer);
		}

		public override function processFileSegment(input:IDataInput):ByteArray
		{
			return basicProcessFileSegment(input, false);
		}
		
		public override function endProcessFile(input:IDataInput):ByteArray
		{
			if ( key && !key.isLoaded ) trace("HIT END OF FILE WITH NO KEY!");

			if ( key ) key.usePadding = true;

			// Note the start as a debug event.
			_parser.sendDebugEvent( {type:"segmentEnd", uri:segmentUri});
			
			var rv:ByteArray = basicProcessFileSegment(input, true);
			
			var elapsed:Number = _segmentLastSeconds - _segmentBeginSeconds;
			
			// Also update end time - don't trace it as we'll increase it incrementally.
			if(HLSIndexHandler.endTimeWitnesses[segmentUri] == null && !isBestEffort)
			{
				trace("Noting segment end time for " + segmentUri + " of " + _segmentLastSeconds);
				if(_segmentLastSeconds != _segmentLastSeconds)
					throw new Error("Got a NaN _segmentLastSeconds for " + segmentUri + "!");
				HLSIndexHandler.endTimeWitnesses[segmentUri] = _segmentLastSeconds;
			}

			if(elapsed <= 0.0 && _extendedIndexHandler)
			{
				elapsed = _extendedIndexHandler.getTargetSegmentDuration(); // XXX fudge hack!
			}

			dispatchEvent(new HTTPStreamingEvent(HTTPStreamingEvent.FRAGMENT_DURATION, false, false, elapsed));
			
			return rv;
		}
		
		public override function flushFileSegment(input:IDataInput):ByteArray
		{
			return basicProcessFileSegment(input || new ByteArray(), true);
		}
		
		public static var flvLowWaterAudio:uint = 0;
		public static var flvLowWaterVideo:uint = 0;
		public const filterThresholdMs:uint = 0;
				
		public static var flvLowWaterAudio:uint = 0;
		public static var flvLowWaterVideo:uint = 0;
		public static var flvRecoveringIFrame:Boolean = false;
		public const filterThresholdMs:uint = 0;

		private function clearFLVWaterMarkFilter():void
		{
			flvLowWaterAudio = 0;
			flvLowWaterVideo = 0;
			flvRecoveringIFrame = false;
		}

		private function handleFLVMessage(timestamp:uint, message:ByteArray):void
		{
			var timestampSeconds:Number = timestamp / 1000.0;

			if(_segmentBeginSeconds < 0)
			{
				_segmentBeginSeconds = timestampSeconds;
				trace("Noting segment start time for " + segmentUri + " of " + timestampSeconds);
				HLSIndexHandler.startTimeWitnesses[segmentUri] = timestampSeconds;
			}

			if(timestampSeconds > _segmentLastSeconds)
				_segmentLastSeconds = timestampSeconds;

			if(isBestEffort)
				return;

			var type:int = message[0];

			// Alway pass through SPS/PPS...
			var alwaysPass:Boolean = false
			var isKeyFrame:Boolean = false;
			if(type == 9)
			{
				if(message[11] == FLVTags.VIDEO_CODEC_AVC_KEYFRAME
					&& message[12] == FLVTags.AVC_MODE_AVCC)
				{
					trace("Got AVCC, always pass.");
					alwaysPass = true;
				}

				if(message[11] == FLVTags.VIDEO_CODEC_AVC_KEYFRAME)
					isKeyFrame = true;
			}

			if(type == 9)
			{
				var videoWasBelowWatermark:Boolean = (timestamp < flvLowWaterVideo - filterThresholdMs);
				var willSkip:Boolean = false;

				if(flvRecoveringIFrame)
				{
					// Skip until we encounter an I-frame past the filter threshold.
					willSkip = true;
					if(isKeyFrame && !videoWasBelowWatermark)
					{
						// We got past filter and saw an I-frame... stop recovery.
						flvRecoveringIFrame = false;
						willSkip = false;
					}
				}
				else
				{
					if(videoWasBelowWatermark && !alwaysPass)
					{
						flvRecoveringIFrame = true;
						willSkip = true;
					}
				}

				if(willSkip)
				{
					trace("SKIPPING TOO LOW FLV VID TS @ " + timestamp);
					if(SEND_LOGS)
					{
						ExternalInterface.call("onTag(" + timestampSeconds + ", " + type + "," + flvLowWaterAudio + "," + flvLowWaterVideo + ", false, " + isKeyFrame + ")");
					}
					return;
				}

				// Don't update low water if it's an always pass.
				if(!alwaysPass)
					flvLowWaterVideo = timestamp;				
			}
			else if(type == 8)
			{
				if(timestamp <= flvLowWaterAudio - filterThresholdMs)
				{
					trace("SKIPPING TOO LOW FLV AUD TS @ " + timestamp);
					if(SEND_LOGS)
					{
						ExternalInterface.call("onTag(" + timestampSeconds + ", " + type + "," + flvLowWaterAudio + "," + flvLowWaterVideo + ", false, " + isKeyFrame + ")");
					}
					return;
				}

				flvLowWaterAudio = timestamp;					
			}

			if(SEND_LOGS)
			{
				ExternalInterface.call("onTag(" + timestampSeconds + ", " + type + "," + flvLowWaterAudio + "," + flvLowWaterVideo + ", true, " + isKeyFrame + ")");			
			}

			//trace("Got " + message.length + " bytes at " + timestampSeconds + " seconds");

			if(_timeOriginNeeded)
			{
				_timeOrigin = timestamp;
				_timeOriginNeeded = false;
			}
			
			if(timestamp < _timeOrigin)
				_timeOrigin = timestamp;
			
			// Encode the timestamp.
			message[6] = (timestamp      ) & 0xff;
			message[5] = (timestamp >>  8) & 0xff;
			message[4] = (timestamp >> 16) & 0xff;
			message[7] = (timestamp >> 24) & 0xff;

			var lastMsgTime:Number = _lastFLVMessageTime;
			_lastFLVMessageTime = timestampSeconds;
			
			// If timer was reset due to seek, reset last subtitle time
			if(timestampSeconds < _lastInjectedSubtitleTime)
			{
				trace("Bumping back on subtitle threshold.")
				_lastInjectedSubtitleTime = timestampSeconds;
			} 
			
			// Inject any subtitle tags between messages
			injectSubtitles( _lastInjectedSubtitleTime + 0.001, timestampSeconds );
			
			//trace( "MESSAGE RECEIVED " + timestampSeconds );
			
			_buffer.writeBytes(message);
		}

		protected var _lastCue:TextTrackCue = null;
		
		private function injectSubtitles( startTime:Number, endTime:Number ):void
		{
			//if(startTime > endTime) trace("***** BAD BEHAVIOR " + startTime + " " + endTime);

			//trace("Inject subtitles " + startTime + " " + endTime);

			// Early out if no subtitles, no time has elapsed or we are already injecting subtitles
			if ( !subtitleTrait || endTime - startTime <= 0 || _injectingSubtitles ) return;
			
			var subtitles:Vector.<SubTitleParser> = subtitleTrait.activeSubtitles;
			if ( !subtitles ) return;
			
			_injectingSubtitles = true;
			
			var subtitleCount:int = subtitles.length;
			for ( var i:int = 0; i < subtitleCount; i++ )
			{
				var subtitle:SubTitleParser = subtitles[ i ];
				if ( subtitle.startTime > endTime ) break;
				var cues:Vector.<TextTrackCue> = subtitle.textTrackCues;
				var cueCount:int = cues.length;
				
				var potentials:Vector.<TextTrackCue> = new Vector.<TextTrackCue>();

				for ( var j:int = 0; j < cueCount; j++ )
				{
					var cue:TextTrackCue = cues[ j ];
					if ( cue.startTime > endTime ) break;
					else if ( cue.startTime >= startTime )
					{
						potentials.push(cue);
					}
				}

				if(potentials.length > 0)
				{
					// TODO: Add support for trackid
					cue = potentials[potentials.length - 1];
					if(cue != _lastCue)
					{
						_parser.createAndSendCaptionMessage( cue.startTime, cue.text, subtitleTrait.language );
						_lastInjectedSubtitleTime = cue.startTime;
						_lastCue = cue;						
					}
				}
			}
			
			_injectingSubtitles = false;
		}
	}
}