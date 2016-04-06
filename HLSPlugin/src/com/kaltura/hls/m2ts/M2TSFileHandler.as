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
	
	import mx.utils.Base64Encoder;

	import flash.external.ExternalInterface;
	
	import org.osmf.events.HTTPStreamingEvent;
	import org.osmf.net.httpstreaming.HTTPStreamingFileHandlerBase;
	import org.osmf.net.httpstreaming.flv.FLVTagAudio;

	CONFIG::LOGGING
	{
		import org.osmf.logging.Logger;
        import org.osmf.logging.Log;
	}

	/**
	 * Process M2TS data into FLV data and return it for rendering via OSMF video system.
	 */
	public class M2TSFileHandler extends HTTPStreamingFileHandlerBase
	{
        CONFIG::LOGGING
        {
            private static const logger:Logger = Log.getLogger("com.kaltura.hls.m2ts.M2TSFileHandler");
        }

		public static var SEND_LOGS:Boolean = false;
		
		public var subtitleTrait:SubtitleTrait;
		public var key:HLSManifestEncryptionKey;
		public var segmentId:uint = 0;
		public var resource:HLSStreamingResource;
		public var segmentUri:String;
		public var isBestEffort:Boolean = false;
		
		private var _parser:TSPacketParser;
		private var _buffer:ByteArray;
		private var _fragReadBuffer:ByteArray;
		private var _encryptedDataBuffer:ByteArray;
		private var _timeOrigin:Number;
		private var _timeOriginNeeded:Boolean;
		private var _segmentBeginSeconds:Number;
		private var _segmentLastSeconds:Number;
		private var _firstSeekTime:Number;
		private var _lastContinuityToken:String;
		private var _extendedIndexHandler:IExtraIndexHandlerState;
		private var _injectingSubtitles:Boolean = false;
		private var _lastInjectedSubtitleTime:Number = 0;
		private var _lastSixteenBytes:ByteArray;
		
		private var _decryptionIV:ByteArray;
		
		public var flvLowWaterAudio:int = int.MIN_VALUE;
		public var flvLowWaterVideo:int = int.MIN_VALUE;
		public var flvRecoveringIFrame:Boolean = false;
		public const filterThresholdMs:int = 64;

		public function M2TSFileHandler()
		{
			super();
			
			_encryptedDataBuffer = new ByteArray();
			_lastSixteenBytes = new ByteArray();

			_parser = new TSPacketParser();
			_parser.callback = handleFLVMessage;
			_parser.id3Callback = handleID3;
			
			_timeOrigin = 0;
			_timeOriginNeeded = true;
			
			_segmentBeginSeconds = Number.MAX_VALUE;
			_segmentLastSeconds = -Number.MAX_VALUE;
			
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

		public function get hasVideo():Boolean
		{
			return _parser.hasVideo;
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
			aacParser = null;

			if( key && !key.isLoading && !key.isLoaded)
				throw new Error("Tried to process segment with key not set to load or loaded.");

			if(isBestEffort)
			{
				CONFIG::LOGGING
				{
					logger.debug("Doing extra flush for best effort file handler");
				}
				_parser.flush();
				_parser.clear();
			}

			// Decryption reset
			if ( key )
			{
				CONFIG::LOGGING
				{
					logger.debug("Resetting _decryptionIV");
				}
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
			
			_segmentBeginSeconds = Number.MAX_VALUE;
			_segmentLastSeconds = -Number.MAX_VALUE;
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

		protected var aacParser:AACParser = null;
		protected var aacAccumulator:ByteArray = new ByteArray(); // AAC bytes we haven't processed yet.

		private function basicProcessFileSegment(input:IDataInput, _flush:Boolean):ByteArray
		{
			if ( key && !key.isLoaded )
			{
				CONFIG::LOGGING
				{
					logger.debug("basicProcessFileSegment - Waiting on key to download.");					
				}

				if(input)
					input.readBytes( _encryptedDataBuffer, _encryptedDataBuffer.length );
				return null;
			}
			
			tmpBuffer.position = 0;
			tmpBuffer.length = 0;
			
			if ( _encryptedDataBuffer.length > 0 )
			{
				CONFIG::LOGGING
				{
					logger.debug("Restoring " + _encryptedDataBuffer.length + " bytes of encrypted data.");
				}

				// Restore any pending encrypted data.
				_encryptedDataBuffer.position = 0;
				_encryptedDataBuffer.readBytes( tmpBuffer );
				_encryptedDataBuffer.clear();
			}

			//Check to see if we have 16 bytes saved from the end of the last pass
			if (_lastSixteenBytes.length > 0)
			{
				//Feeds them in at the beginning of the temp buffer, after any encryptedData
				_lastSixteenBytes.position = 0;
				_lastSixteenBytes.readBytes(tmpBuffer, tmpBuffer.length);
				_lastSixteenBytes.length = 0;
				_lastSixteenBytes.position = 0;
			}

			if(!input)
				input = new ByteArray();

			var amountToRead:int = input.bytesAvailable;
			if(amountToRead > 1024*128) amountToRead = 1024*128;

			CONFIG::LOGGING
			{
				logger.debug("READING " + amountToRead + " OF " + input.bytesAvailable);
			}

			if(amountToRead > 0)
				input.readBytes( tmpBuffer, tmpBuffer.length, amountToRead);

			if ( key )
			{
				//If we aren't flushing at the end of a segment and we have 16 bytes, save the last 16 bytes off the end 
				//in case they are padding. If we don't save the data and then attempt unpadding at the end, it may try 
				//unpadding in the middle of a segment. If it does this and the data happens to look like padding, it will 
				//truncate good bytes and cause pixelation
				if (!_flush && tmpBuffer.length >= 16);
				{
					tmpBuffer.position = tmpBuffer.length - 16;
					tmpBuffer.readBytes(_lastSixteenBytes, 0, 16);
					tmpBuffer.length -= 16;
					tmpBuffer.position = 0;
				}
				else
				{
					//If we are flushing, reset the ByteArray so no leftover data is around for the first pass on the next segment
					_lastSixteenBytes.length = 0;
					_lastSixteenBytes.position = 0;
				}

				// We need to decrypt available data.
				var bytesToRead:uint = tmpBuffer.length;
				var leftoverBytes:uint = bytesToRead % 16;
				bytesToRead -= leftoverBytes;

				CONFIG::LOGGING
				{
					logger.debug("Decrypting " + tmpBuffer.length + " bytes of encrypted data.");
				}
				
				//key.usePadding = false;
				
				if ( leftoverBytes > 0 )
				{
					// Place any bytes left over (not divisible by 16) into our encrypted buffer
					// to decrypt later, when we have more bytes
					tmpBuffer.position = bytesToRead;
					tmpBuffer.readBytes( _encryptedDataBuffer );
					tmpBuffer.length = bytesToRead;

					CONFIG::LOGGING
					{
						logger.debug("Storing " + _encryptedDataBuffer.length + " bytes of encrypted data.");
					}
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
			
			// Check for AAC content.
			if(!aacParser && AACParser.probe(tmpBuffer))
			{
				aacParser = new AACParser();
				//logger.debug("GOT AAC " + tmpBuffer.length);
			}

			// If we know we're an AAC, process it.
			if(aacParser)
			{
				_fragReadBuffer = new ByteArray();

				// Stick any bytes that we have into the AAC accumulator...
				//logger.debug("Adding to AAC accum " + tmpBuffer.length + " bytes");
				var oldLen:int = aacAccumulator.length;
				aacAccumulator.length += tmpBuffer.length;
				aacAccumulator.position = oldLen;
				aacAccumulator.writeBytes(tmpBuffer, 0, tmpBuffer.length);
				//logger.debug("accum now " + aacAccumulator.length);

				var aacBytesRead:int = aacParser.parse(aacAccumulator, _fragReadHandler, _flush);
				//logger.debug("AAC parsed " + aacBytesRead + " bytes out of " + aacAccumulator.length);

				// Save off any bytes we haven't processed yet.
				if(aacBytesRead > 0 && aacBytesRead < aacAccumulator.length)
				{
					//logger.debug("Moving bytes to beginning");
					// Move remaining bytes to beginning.
					aacAccumulator.writeBytes(aacAccumulator, aacBytesRead, aacAccumulator.length - aacBytesRead);
					aacAccumulator.length -= aacBytesRead;
					//logger.debug("Bytes left: " + aacAccumulator.length);
				}
				else if(aacBytesRead >= aacAccumulator.length)
				{
					//logger.debug("Read too many bytes; assuming that means all of them.");
					aacAccumulator.length = 0;
				}

				if(isBestEffort && _fragReadBuffer.length > 0)
				{
					CONFIG::LOGGING
					{
						logger.debug("Discarding AAC data from best effort.");
					}
					_fragReadBuffer.length = 0;
				}

				_fragReadBuffer.position = 0;
				//logger.debug("Returning " + _fragReadBuffer.length + " bytes of AAC data");
				return _fragReadBuffer;
			}
			
			// Parse it as MPEG TS data.
			var buffer:ByteArray = new ByteArray();
			_buffer = buffer;
			_parser.appendBytes(tmpBuffer);
			if ( _flush ) 
			{
				CONFIG::LOGGING
				{
					logger.debug("flushing parser");
				}
				_parser.flush();
			}

			if(isBestEffort)
			{
				// Force processing immediately. We only need a starting timestamp.
				trace("Extracting timestamps for BEF.");
				_parser.handleBestEffortProcess();
			}

			_buffer = null;
			buffer.position = 0;

			// Throw it out if it's a best effort fetch.
			if(isBestEffort && buffer.length > 0)
			{
				CONFIG::LOGGING
				{
					logger.debug("Discarding normal data from best effort.");
				}

				buffer.length = 0;
			}

			if(buffer.length == 0)
				return null;

			return buffer;
		}
		
		private function _fragReadHandler(audioTags:Vector.<FLVTagAudio>, adif:ByteArray):void 
		{
			var audioTag:FLVTagAudio = new FLVTagAudio();
			audioTag.soundFormat = FLVTagAudio.SOUND_FORMAT_AAC;
			audioTag.data = adif;
			audioTag.isAACSequenceHeader = true;
			audioTag.write(_fragReadBuffer);
			
			for(var i:int=0; i<audioTags.length; i++)
			{
				var timestampSeconds:Number = audioTags[i].timestamp / 1000.0;
				//trace("Writing AAC Tag @ " + timestampSeconds)
				_segmentLastSeconds = timestampSeconds;

				if(timestampSeconds < _segmentBeginSeconds)
				{
					_segmentBeginSeconds = timestampSeconds;

					CONFIG::LOGGING
					{
						logger.info("Noting segment start time for " + segmentUri + " of " + timestampSeconds);
					}

					HLSIndexHandler.startTimeWitnesses[segmentUri] = timestampSeconds;
				}

				if(!isBestEffort)
					audioTags[i].write(_fragReadBuffer);
			}
		}

		public override function processFileSegment(input:IDataInput):ByteArray
		{
			if (key)
			{
				// If we are working with encrypted data, don't try to unpad because we haven't finished the segment
				key.usePadding = false;
			}
			return basicProcessFileSegment(input, false);
		}
		
		public override function endProcessFile(input:IDataInput):ByteArray
		{
			CONFIG::LOGGING
			{
				if ( key && !key.isLoaded )
				{
					logger.error("HIT END OF FILE WITH NO KEY!");
				}
			}

			if ( key ) key.usePadding = true;

			// Note the end as a debug event.
			_parser.sendDebugEvent( {type:"segmentEnd", uri:segmentUri});
			
			var rv:ByteArray = basicProcessFileSegment(input, true);
			
			var elapsed:Number = _segmentLastSeconds - _segmentBeginSeconds;
			
			// Also update end time - don't trace it as we'll increase it incrementally.
			if(HLSIndexHandler.endTimeWitnesses[segmentUri] == null && !isBestEffort)
			{
				CONFIG::LOGGING
				{
					logger.info("Noting segment end time for " + segmentUri + " of " + _segmentLastSeconds);
				}

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
		
		private function handleID3(message:ByteArray, timestamp:Number):void
		{
			if (!message || isBestEffort)
				return;

			CONFIG::LOGGING
			{
				logger.debug("Processing ID3 @ " + timestamp + "ms");
			}				
			message.position = 0;
			var b64:Base64Encoder = new Base64Encoder();
			b64.encodeBytes(message);
			_parser.createAndSendID3Message(timestamp,b64.toString());
		}
			
		private function handleFLVMessage(timestamp:int, message:ByteArray, duration:int):void
		{
			var timestampSeconds:Number = timestamp / 1000.0;
			var endTimestampSeconds:Number = (timestamp + duration) / 1000.0;

			if(timestampSeconds < _segmentBeginSeconds)
			{
				_segmentBeginSeconds = timestampSeconds;

				CONFIG::LOGGING
				{
					logger.info("Noting segment start time for " + segmentUri + " of " + timestampSeconds);
				}

				HLSIndexHandler.startTimeWitnesses[segmentUri] = timestampSeconds;
			}

			if(endTimestampSeconds > _segmentLastSeconds)
				_segmentLastSeconds = endTimestampSeconds;

			if(isBestEffort)
				return;

			var type:int = message[0];

			if(SEND_LOGS)
			{
				var alwaysPass:Boolean = false
				var isKeyFrame:Boolean = false;
				if(type == 9 && message[11] == FLVTags.VIDEO_CODEC_AVC_KEYFRAME)
						isKeyFrame = true;
				
				ExternalInterface.call("onTag(" + timestampSeconds + ", " + type + "," + 0 + "," + 0 + ", true, " + isKeyFrame + ")");	
			}

			//logger.debug("Got FLV " + type + " with " + message.length + " bytes at " + timestampSeconds + " seconds");

			if(_timeOriginNeeded)
			{
				_timeOrigin = timestamp;
				_timeOriginNeeded = false;
			}
			
			if(timestamp < _timeOrigin)
				_timeOrigin = timestamp;
			
			// Encode the timestamp.
			message[4] = (timestamp >> 16) & 0xff;
			message[5] = (timestamp >>  8) & 0xff;
			message[6] = (timestamp      ) & 0xff;
			message[7] = (timestamp >> 24) & 0xff;

			// If timer was reset due to seek, reset last subtitle time
			if(timestampSeconds < _lastInjectedSubtitleTime)
			{
				CONFIG::LOGGING
				{
					logger.debug("Bumping back on subtitle threshold.")
				}
				
				_lastInjectedSubtitleTime = timestampSeconds;
			} 
			
			// Inject any subtitle tags between messages
			injectSubtitles( _lastInjectedSubtitleTime + 0.001, timestampSeconds );
			
			//logger.debug( "MESSAGE RECEIVED " + timestampSeconds );
			
			_buffer.writeBytes(message);
		}

		protected var _lastCue:TextTrackCue = null;
		
		private function injectSubtitles( startTime:Number, endTime:Number ):void
		{
			//if(startTime > endTime) logger.debug("***** BAD BEHAVIOR " + startTime + " " + endTime);

			//logger.debug("Inject subtitles " + startTime + " " + endTime);

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
