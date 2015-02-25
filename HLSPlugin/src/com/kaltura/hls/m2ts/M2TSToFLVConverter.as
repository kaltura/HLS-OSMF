package com.kaltura.hls.m2ts
{
	import flash.net.ObjectEncoding;
	import flash.utils.ByteArray;
	import flash.utils.Endian;
	
	import mx.utils.Base64Encoder;
	
	/**
	 * Accept data from a M2TS and emit a valid FLV stream.
	 */
	public class M2TSToFLVConverter implements IM2TSCallbacks
	{	
		public static var _masterBuffer:ByteArray = new ByteArray();	

		private var _aacConfig:ByteArray;
		private var _aacRemainder:ByteArray;
		private var _aacTimestamp:Number;

		private var _avcPacket:ByteArray;
		private var _avcPTS:Number;
		private var _avcDTS:Number;
		private var _avcVCL:Boolean;
		private var _avcAccessUnitStarted:Boolean;

		private var _seiRBSPBuffer:ByteArray;
		
		private var _pendingCaptionInfos:Array;

		private var _parser:M2TSParser;
		private var _handler:Function;
		private var _keyFrame:Boolean;
		private var _sendAVCC:Boolean;
	
		private var _sps:ByteArray;
		private var _pps:ByteArray;
		
		public function M2TSToFLVConverter(messageHandler:Function = null)
		{
			_parser = new M2TSParser(this);
			_keyFrame = false;
			_sendAVCC = false;
			_sps = null;
			_pps = null;
			_avcPacket = new ByteArray;
			_avcPTS = -1;
			_avcDTS = -1;
			_aacRemainder = null;
			_aacTimestamp = -1.0;
			_seiRBSPBuffer = new ByteArray();
			_pendingCaptionInfos = [];
			setMessageHandler(messageHandler);
		}
		
		public static function generateFLVHeader(video:Boolean = true, audio:Boolean = true):ByteArray
		{
			var header:ByteArray = new ByteArray();
			
			header[0] = 0x46; // F
			header[1] = 0x4c; // L
			header[2] = 0x56; // V
			header[3] = 0x01; // version = 1
			header[4] = (video ? FLVTags.HEADER_VIDEO_FLAG : 0) + (audio ? FLVTags.HEADER_AUDIO_FLAG : 0); // flags
			header[5] = 0x00; // header length == 9
			header[6] = 0x00;
			header[7] = 0x00;
			header[8] = 0x09; 
			header[9] = 0x00; // back pointer == 0
			header[10] = 0x00;
			header[11] = 0x00;
			header[12] = 0x00; 
			
			return header;
		}
		
		public function setMessageHandler(messageHandler:Function = null):void
		{
			if(null == messageHandler)
				messageHandler = _nullMessageHandler;
			
			_handler = messageHandler;
		}
		
		public function appendBytes(bytes:ByteArray):void
		{
			_parser.appendBytes(bytes);
		}
		
		public function flush():void
		{
			_parser.flush();
			_avcPacket.length = 0;
			_avcPTS = -1;
			_avcDTS = -1;
			_avcVCL = false;
			_avcAccessUnitStarted = false;
			_aacRemainder = null;
			_aacTimestamp = -1.0;
		}
		
		public function clear(clearACCConfig:Boolean = true):void
		{
			_parser.clear();
			_avcPacket.length = 0;
			_avcVCL = false;
			_avcAccessUnitStarted = false;
			_aacRemainder = null;
			_aacTimestamp = -1.0;
			_sps = null;
			_pps = null;
			
			if(clearACCConfig)
				_aacConfig = null;
		}
		
		public function reset():void
		{
			_parser.reset();
			clear();
		}
		
		private function convertFLVTimestamp(ts:Number):uint
		{
			return uint(ts) / 90;
		}
		
		public function onOtherElementaryPacket(packetID:uint, type:uint, pts:Number, dts:Number, cursor:uint, bytes:ByteArray):void
		{
		}
		
		public function onOtherPacket(packetID:uint, bytes:ByteArray):void
		{
		}
		
		public function onMP3Packet(pts:Number, dts:Number, bytes:ByteArray, cursor:uint, length:uint):void
		{
			_aacConfig = null;
			sendFLVTag(convertFLVTimestamp(pts), FLVTags.TYPE_AUDIO, FLVTags.AUDIO_CODEC_MP3, -1, bytes, cursor, length);
		}
		
		public function onAACPacket(timestamp:Number, bytes:ByteArray, cursor:uint, length:uint):void
		{
			//trace("ENTER onAACPacket " + timestamp + "," + cursor + "," + length );

			var timeAccumulation:Number = 0.0;
			var limit:uint;
			var stream:ByteArray;
			var hadRemainder:Boolean = false;
			
			if(_aacRemainder)
			{
				stream = _aacRemainder;
				stream.writeBytes(bytes, cursor, length);
				cursor = 0;
				length = stream.length;
				_aacRemainder = null;
				hadRemainder = true;
				timeAccumulation = _aacTimestamp - timestamp;
			}
			else
				stream = bytes;
			
			limit = cursor + length;
			
			// an AAC PES packet can contain multiple ADTS frames
			while(cursor < limit)
			{
				var remaining:uint = limit - cursor;
				var sampleRateIndex:uint;
				var sampleRate:Number = undefined;
				var profile:uint;
				var channelConfig:uint;
				var frameLength:uint;
				
				if(remaining < FLVTags.ADTS_FRAME_HEADER_LENGTH)
					break;
				
				// search for syncword
				if(stream[cursor] != 0xff || (stream[cursor + 1] & 0xf0) != 0xf0)
				{
					cursor++;
					continue;
				}
				
				frameLength  = (stream[cursor + 3] & 0x03) << 11;
				frameLength += (stream[cursor + 4]) << 3;
				frameLength += (stream[cursor + 5] >> 5) & 0x07;
				
				// Check for an invalid ADTS header; if so look for next syncword.
				if(frameLength < FLVTags.ADTS_FRAME_HEADER_LENGTH)
				{
					cursor++;
					continue;
				}
				
				// Skip it till next PES packet.
				if(frameLength > remaining)
					break;
				
				profile = (stream[cursor + 2] >> 6) & 0x03;
				
				sampleRateIndex = (stream[cursor + 2] >> 2) & 0x0f;
				switch(sampleRateIndex)
				{
					case 0x00:
						sampleRate = 96000.0;
						break;
					case 0x01:
						sampleRate = 88200.0;
						break;
					case 0x02:
						sampleRate = 64000.0;
						break;
					case 0x03:
						sampleRate = 48000.0;
						break;
					case 0x04:
						sampleRate = 44100.0;
						break;
					case 0x05:
						sampleRate = 32000.0;
						break;
					case 0x06:
						sampleRate = 24000.0;
						break;
					case 0x07:
						sampleRate = 22050.0;
						break;
					case 0x08:
						sampleRate = 16000.0;
						break;
					case 0x09:
						sampleRate = 12000.0;
						break;
					case 0x0a:
						sampleRate = 11025.0;
						break;
					case 0x0b:
						sampleRate = 8000.0;
						break;
					case 0x0c:
						sampleRate = 7350.0;
						break;
				}
				
				channelConfig = ((stream[cursor + 2] & 0x01) << 2) + ((stream[cursor + 3] >> 6) & 0x03);
				
				if(sampleRate)
				{
					var flvts:uint = convertFLVTimestamp(timestamp + timeAccumulation);
					
					sendAACConfigFLVTag(flvts, profile, sampleRateIndex, channelConfig);
					//trace("Sending AAC");
					sendFLVTag(flvts, FLVTags.TYPE_AUDIO, FLVTags.AUDIO_CODEC_AAC, FLVTags.AAC_MODE_FRAME, stream, cursor + FLVTags.ADTS_FRAME_HEADER_LENGTH, frameLength - FLVTags.ADTS_FRAME_HEADER_LENGTH);
					
					timeAccumulation += (1024.0 / sampleRate) * 90000.0; // account for the duration of this frame
					
					if(hadRemainder)
					{
						timeAccumulation = 0.0;
						hadRemainder = false;
					}
				}
				
				cursor += frameLength;
			}
			
			if(cursor < limit)
			{
				//trace("AAC timestamp was " + _aacTimestamp);
				_aacRemainder = new ByteArray();
				_aacRemainder.writeBytes(stream, cursor, limit - cursor);
				_aacTimestamp = timestamp + timeAccumulation;
				//trace("AAC timestamp now " + _aacTimestamp);
			}
		}
		
		private function compareBytesHelper(b1:ByteArray, b2:ByteArray):Boolean
		{
			var curPos:uint;
			
			if(b1.length != b2.length)
				return false;
			
			for(curPos = 0; curPos < b1.length; curPos++)
			{
				if(b1[curPos] != b2[curPos])
					return false;
			}
			
			return true;
		}
		
		private function sendAACConfigFLVTag(flvts:uint, profile:uint, sampleRateIndex:uint, channelConfig:uint):void
		{
			var isNewConfig:Boolean = true;
			var audioSpecificConfig:ByteArray = new ByteArray();
			var audioObjectType:uint;
			
			audioSpecificConfig.length = 2;
			
			switch(profile)
			{
				case 0x00:
					audioObjectType = 0x01;
					break;
				case 0x01:
					audioObjectType = 0x02;
					break;
				case 0x02:
					audioObjectType = 0x03;
					break;
				default:
					return;
			}
			
			audioSpecificConfig[0] = ((audioObjectType << 3) & 0xf8) + ((sampleRateIndex >> 1) & 0x07);
			audioSpecificConfig[1] = ((sampleRateIndex << 7) & 0x80) + ((channelConfig << 3) & 0x78);
			
			if(_aacConfig && compareBytesHelper(_aacConfig, audioSpecificConfig))
				isNewConfig = false;
			
			if(!isNewConfig)
				return;

			_aacConfig = audioSpecificConfig;
			sendFLVTag(flvts, FLVTags.TYPE_AUDIO, FLVTags.AUDIO_CODEC_AAC, FLVTags.AAC_MODE_CONFIG, _aacConfig, 0, _aacConfig.length);
		}
		
		private function generateScriptData(values:Array):ByteArray
		{
			var bytes:ByteArray = new ByteArray();
			bytes.objectEncoding = ObjectEncoding.AMF0;
			
			for each (var object:Object in values)
				bytes.writeObject(object);
			
			return bytes;
		}
		
		private function sendScriptDataFLVTag(flvts:uint, values:Array):void
		{
			var bytes:ByteArray = generateScriptData(values);
			sendFLVTag(flvts, FLVTags.TYPE_SCRIPTDATA, -1, -1, bytes, 0, bytes.length);
		}
		
		static var passFirst:int = 10;
		static var flvBuffer:Array = [];

		//sorting function
		public function randomSort(objA:Object, objB:Object):int{
		    return Math.round(Math.random() * 2) - 1;
		}

		private function sendFLVTag(flvts:uint, type:uint, codec:int, mode:int, bytes:ByteArray, offset:uint, length:uint):void
		{
			var tag:ByteArray = new ByteArray();
			var msgLength:uint = length + ((codec >= 0) ? 1 : 0) + ((mode >= 0) ? 1 : 0);
			var cursor:uint = 0;
			
			if(msgLength > 0xffffff)
				return; // too big for the length field
			
			tag.length = FLVTags.HEADER_LENGTH + msgLength + FLVTags.PREVIOUS_LENGTH_LENGTH; // header + msgLength + 4-byte back pointer
			tag[cursor++] = type;
			tag[cursor++] = (msgLength >> 16) & 0xff;
			tag[cursor++] = (msgLength >>  8) & 0xff;
			tag[cursor++] = (msgLength      ) & 0xff;
			tag[cursor++] = (flvts >> 16) & 0xff;
			tag[cursor++] = (flvts >>  8) & 0xff;
			tag[cursor++] = (flvts      ) & 0xff;
			tag[cursor++] = (flvts >> 24) & 0xff;
			tag[cursor++] = 0x00;
			tag[cursor++] = 0x00;
			tag[cursor++] = 0x00;
			
			if(codec >= 0)
				tag[cursor++] = codec;
			if(mode >= 0)
				tag[cursor++] = mode;
			
			tag.position = cursor;
			tag.writeBytes(bytes, offset, length);
			
			cursor += length;
			msgLength += 11; // account for message header in back pointer
			tag[cursor++] = (msgLength >> 24) & 0xff;
			tag[cursor++] = (msgLength >> 16) & 0xff;
			tag[cursor++] = (msgLength >>  8) & 0xff;
			tag[cursor++] = (msgLength      ) & 0xff;


// Useful filtering/debug code.			
if(false) {
			if(type != FLVTags.TYPE_AUDIO)
			{
				trace("SKIPPING NON-AUDIO TAG! ***********************");
				return;
			}

			// Randomize things.
			if(passFirst > 0)
			{
				// NOP first few things.
				passFirst--;
			}
			else
			{
				// Push until we have 5 then start pulling random items.
				flvBuffer.push([flvts, tag]);
				if(flvBuffer.length < 5)
					return;

				flvBuffer.sort(randomSort);
				var outItem:Array = flvBuffer.pop() as Array;
				if(outItem)
				{
					_handler(outItem[0], outItem[1]);
				}
			}
			return;
}
			//trace("FLV Emit " + flvts);

			_handler(flvts, tag);

			// Uncomment to log all FLV for investigation.
			//_masterBuffer.writeBytes(tag);
		}
		
		private function makeAVCC():ByteArray
		{
			if( !_sps || !_pps)
				return null;
			
			var spsLength:uint = _sps.length;
			var ppsLength:uint = _pps.length;
			
			var avcc:ByteArray = new ByteArray();
			var cursor:uint = 0;
			
			avcc[cursor++] = 0;
			avcc[cursor++] = 0;
			avcc[cursor++] = 0;
			avcc[cursor++] = 1; // version
			avcc[cursor++] = _sps[1]; // profile
			avcc[cursor++] = _sps[2]; // compatiblity
			avcc[cursor++] = _sps[3]; // level
			avcc[cursor++] = 0xff; // nalu length length = 4 bytes: 111111xx, 00=1, 01=2, 10=3, 11=4
			avcc[cursor++] = 0x01; // one SPS
			avcc[cursor++] = (spsLength >> 8) & 0xff;
			avcc[cursor++] = (spsLength     ) & 0xff;
			avcc.position = cursor;
			avcc.writeBytes(_sps);
			
			// Debug dump the SPS
			//trace("SPS profile " + _sps[1]);
			//trace("SPS compat  " + _sps[2]);
			//trace("SPS level   " + _sps[3]);

			cursor += spsLength;
			
			avcc[cursor++] = 1; // one PPS
			avcc[cursor++] = (ppsLength >> 8) & 0xff;
			avcc[cursor++] = (ppsLength     ) & 0xff;
			avcc.position = cursor;
			avcc.writeBytes(_pps);

			//trace("PPS length is " + ppsLength);

			return avcc;
		}
		
		private function appendAVCNALU(bytes:ByteArray, cursor:uint, length:uint):void
		{
			_avcPacket.writeUnsignedInt(length);
			_avcPacket.writeBytes(bytes, cursor, length);
		}
		
		private static var neverAvcc:Boolean = false;

		private function sendCompleteAVCFLVTag(pts:Number, dts:Number):void
		{
			
			var flvts:uint = convertFLVTimestamp(dts);
			var tsu:uint = convertFLVTimestamp(pts - dts);
			var tmp:ByteArray = new ByteArray;
			
			//trace("pts = " + pts + " dts = " + dts + " tsu = " + tsu + " V");

			if( pts < 0 || dts < 0 || 0 == _avcPacket.length)
				return;
			
			if(_sendAVCC /* && !neverAvcc */)
			{
				neverAvcc = true;

				//trace("Attempting to send AVCC");
				var avcc:ByteArray = makeAVCC();
				
				if(null != avcc)
				{
					//trace("SENDING AVCC");
					sendFLVTag(flvts, FLVTags.TYPE_VIDEO, FLVTags.VIDEO_CODEC_AVC_KEYFRAME, FLVTags.AVC_MODE_AVCC, avcc, 0, avcc.length);
					_sendAVCC = false;
				}
			}
			
			var codec:uint;
			if(_keyFrame)
				codec = FLVTags.VIDEO_CODEC_AVC_KEYFRAME;
			else
				codec = FLVTags.VIDEO_CODEC_AVC_PREDICTIVEFRAME;
			
			tmp.length = 3 + length;
			tmp[0] = (tsu >> 16) & 0xff;
			tmp[1] = (tsu >>  8) & 0xff;
			tmp[2] = (tsu      ) & 0xff;
			tmp.position = 3;
			tmp.writeBytes(_avcPacket);
			_avcPacket.length = 0;
			
			sendFLVTag(flvts, FLVTags.TYPE_VIDEO, codec, FLVTags.AVC_MODE_PICTURE, tmp, 0, tmp.length);
		}
		
		private function setAVCSPS(bytes:ByteArray, cursor:uint, length:uint):void
		{
			_sps = new ByteArray;
			_sps.writeBytes(bytes, cursor + 3, length - 3); // skip start code
			_sendAVCC = true;
		}
		
		private function setAVCPPS(bytes:ByteArray, cursor:uint, length:uint):void
		{
			_pps = new ByteArray;
			_pps.writeBytes(bytes, cursor + 3 , length - 3); // skip start code
			_sendAVCC = true;
		}
		
		public function createAndSendCaptionMessage( timeStamp:Number, captionBuffer:String, lang:String="", textid:Number=99):void
		{
			var captionObject:Array = ["onCaptionInfo", { type:"WebVTT", data:captionBuffer }];
			sendScriptDataFLVTag( timeStamp * 1000, captionObject);
			
			// We need to strip the timestamp off of the text data
			captionBuffer = captionBuffer.slice(captionBuffer.indexOf('\n') + 1);
			
			var subtitleObject:Array = ["onTextData", { text:captionBuffer, language:lang, trackid:textid }];
			sendScriptDataFLVTag( timeStamp * 1000, subtitleObject);
		}
		
		private function parseAVCCCData(bytes:ByteArray, cursor:uint, length:uint):void
		{
			var dest:ByteArray = new ByteArray();
			dest.endian = Endian.BIG_ENDIAN;
			dest.writeInt(length);
			if(length)
				dest.writeBytes(bytes, cursor, length);
			
			var tmp:ByteArray = new ByteArray();
			tmp.endian = Endian.BIG_ENDIAN;
			tmp.writeBytes(bytes, cursor, length);
			
			if(false)
			{
				var tmpBuff:String = " Saw ";
				for(var i:int=0; i<tmp.length; i++)
					tmpBuff += tmp[i].toString(16);
				trace(tmpBuff);				
			}
			
			//TeletextParser.processTelxPacket(bytes, 1);
			
			var encoder:Base64Encoder = new Base64Encoder();
			encoder.encodeBytes(dest);
			var encodedDest:String = encoder.toString();
			
			var desiredIndex:uint;
			for(desiredIndex = 0; 
				desiredIndex < _pendingCaptionInfos.length && _pendingCaptionInfos[desiredIndex].pts <= _avcPTS; 
				++desiredIndex) 
			{
			}
			
			var onCaptionInfo:* = ["onCaptionInfo", { type:"708", data:encodedDest }];
			_pendingCaptionInfos.splice(desiredIndex, 0, { pts: _avcPTS, onCaptionInfo:onCaptionInfo });
			sendPendingOnCaptionInfos(false);
		}
		
		private function sendNextPendingOnCaptionInfo(flushing:Boolean):Boolean
		{
			if(_pendingCaptionInfos.length == 0)
				return false;

			var nextInfoPTS:Number = _pendingCaptionInfos[0].pts;
			var nextInfoMessage:* = _pendingCaptionInfos[0].onCaptionInfo;

			if(!flushing && _pendingCaptionInfos.length < 12)
				return false;

			sendScriptDataFLVTag(convertFLVTimestamp(nextInfoPTS), nextInfoMessage);
			_pendingCaptionInfos.shift();
			return true;
		}
		
		private function sendPendingOnCaptionInfos(flushing:Boolean):void
		{
			// Fire all the pending captions.
			var morePending:Boolean = false;
			do
			{
				morePending = sendNextPendingOnCaptionInfo(flushing); 
			}
			while(morePending);
		}
		
		private function parseAndFilterAVCSEI(bytes:ByteArray, cursor:uint, length:uint):void
		{
			var limit:uint = cursor + length;
			var countryCode:uint;
			var providerCode:uint;
			var userIdentifier:uint;
			
			// Filter by caption/AFD/bar.
			countryCode = bytes[cursor++];
			if(countryCode != 0xB5) 
				return;
			
			// Range check.
			if(cursor + 2 >= limit)
				return;
			
			// Filter by provider code.
			providerCode = (bytes[cursor] << 8) + bytes[cursor + 1];
			cursor += 2;
			if(providerCode != 0x0031)
				return;
			
			// Range check.
			if(cursor + 4 >= limit)
				return;
			
			// Filter by user type data (ATSC1)
			userIdentifier  = (bytes[cursor] << 24) + (bytes[cursor + 1] << 16) + (bytes[cursor + 2] << 8) + bytes[cursor + 3];
			cursor += 4;
			if(userIdentifier != 0x47413934)
				return;
			
			// Range check.
			if(cursor + 3 >= limit)
				return;
			
			// And look for cc_data.
			var userDataTypeCode:uint = bytes[cursor++];
			if(0x03 != userDataTypeCode)
				return;
			
			// Awesome - we can parse it.
			parseAVCCCData(bytes, cursor, limit - cursor);
		}
		
		private function parseAVCSEIPayload(payloadType:uint, bytes:ByteArray, cursor:uint, length:uint):void
		{
			if(payloadType != 0x04)
				return;
			
			parseAndFilterAVCSEI(bytes, cursor, length);
		}
		
		private function parseAVCSEIRBSP(bytes:ByteArray, cursor:uint, length:uint):void
		{
			var limit:uint = cursor + length;
			var payloadType:uint;
			var payloadSize:uint;
			var tmp:uint = 0;
			
			while(cursor < limit)
			{
				payloadType = 0;
				payloadSize = 0;
				
				do 
				{
					tmp = bytes[cursor];
					cursor++;
					payloadType += tmp;
				} while ((0xff == tmp) && (cursor < limit));
				
				if(cursor >= limit)
					break;
				
				do {
					tmp = bytes[cursor];
					cursor++;
					payloadSize += tmp;
				} while ((0xff == tmp) && (cursor < limit));
				
				if(cursor + payloadSize > limit)
					break;
				
				parseAVCSEIPayload(payloadType, bytes, cursor, payloadSize);
				
				cursor += payloadSize;
			}
		}
		
		private function parseAVCSEINALU(bytes:ByteArray, cursor:uint, length:uint):void
		{
			var limit:uint = cursor + length;
			
			cursor++; // move over NALU type
			
			_seiRBSPBuffer.position = 0;
			while(cursor < limit)
			{
				if(cursor + 2 < limit &&
					bytes[cursor] == 0x00 &&
					bytes[cursor + 1] == 0x00 &&
					bytes[cursor + 2] == 0x03)
				{
					_seiRBSPBuffer.writeByte(bytes[cursor++]);
					_seiRBSPBuffer.writeByte(bytes[cursor++]);
					cursor++; // skip network emulation byte
				}
				else
				{
					_seiRBSPBuffer.writeByte(bytes[cursor++]);
				}
			}
			
			parseAVCSEIRBSP(_seiRBSPBuffer, 0, _seiRBSPBuffer.position);
		}
		
		public function onAVCNALU(pts:Number, dts:Number, bytes:ByteArray, cursor:uint, length:uint):void
		{
			// What's the type?
			var naluType:uint = bytes[cursor + 3] & 0x1f;
			
			switch(naluType)
			{
				case  6: // SEI
				case  7: // SPS
				case  8: // PPS
				case  9: // Access Unit Delimiter
				case 12: // filler
				case 13: // reserved, triggers access unit start
				case 14: // reserved, triggers access unit start
				case 15: // reserved, triggers access unit start
				case 16: // reserved, triggers access unit start
				case 17: // reserved, triggers access unit start
				case 18: // reserved, triggers access unit start
					
					if(_avcVCL)
					{
						_avcVCL = false;
						_avcAccessUnitStarted = false;
						sendCompleteAVCFLVTag(_avcPTS, _avcDTS);
					}

					if(!_avcAccessUnitStarted)
					{
						_avcAccessUnitStarted = true;
						_avcPTS = pts;
						_avcDTS = dts;
					}
					
					break;
				
				case 1: // VCL
				case 2: // VCL
				case 3: // VCL
				case 4: // VCL
				case 5: // VCL
					if(!_avcAccessUnitStarted)
					{
						_avcAccessUnitStarted = true;
						_avcPTS = pts;
						_avcDTS = dts;
					}
					_avcVCL = true;
					break;
			}
			
			switch(naluType)
			{
				case 0x06: // SEI
					parseAVCSEINALU(bytes, cursor + 3, length - 3); // skip start code
					appendAVCNALU(bytes, cursor + 3, length - 3); // skip start code
					break;

				case 0x07: // SPS
					setAVCSPS(bytes, cursor, length);
					appendAVCNALU(bytes, cursor + 3, length - 3);
					break;
				
				case 0x08: // PPS
					//trace("Grabbing AVC PPS length=" + length);
					setAVCPPS(bytes, cursor, length);
					appendAVCNALU(bytes, cursor + 3, length - 3);
					break;
								
				case 0x09: // "access unit delimiter"
					switch((bytes[cursor + 4] >> 5) & 0x07) // access unit type
					{
						case 0:
						case 3:
						case 5:
							_keyFrame = true;
							break;
						default:
							_keyFrame = false;
							break;
					}
				default:
					// Infer keyframe state.
					if(naluType == 5)
						_keyFrame = true;
					else if(naluType == 1)
						_keyFrame = false;
					
					// Process more NALU; skipping the start code.
					appendAVCNALU(bytes, cursor + 3, length - 3);
					break;
			}
		}
		
		public function onAVCNALUFlush(pts:Number, dts:Number):void
		{
			sendPendingOnCaptionInfos(true);
			_avcVCL = false;
			_avcAccessUnitStarted = false;
			sendCompleteAVCFLVTag(_avcPTS, _avcDTS);
		}
		
		private function _nullMessageHandler(timestamp:uint, message:ByteArray):void 
		{
			// Do nothing.
		}

		private function dumpBytes(prefix:String, bytes:ByteArray, offset:uint, length:uint):void
		{
			var str:String = "";
			
			for(var x:uint = 0; x < length && x < 128; x++)
			{
				var val:uint = bytes[x + offset];
				if(val < 16)
					str += " 0" + val.toString(16);
				else
					str += " " + val.toString(16);
			}
			
			trace(prefix + str);
		}
	}
}