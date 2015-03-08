package com.kaltura.hls.m2ts
{
	import flash.net.ObjectEncoding;
	import flash.utils.ByteArray;
	import flash.utils.Endian;
	import com.hurlant.util.Hex;
	
	/**
	 * Accept data from a M2TS and emit a valid FLV stream.
	 */
	public class M2TSToFLVConverter implements IM2TSCallbacks
	{
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

		public var segmentIndex:int = -1;

		// When true suppress filtering PPS/SPS events.
		public var isBestEffort:Boolean = false;

		public var accumulateParams:Boolean = false;

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

		public function finish():void
		{
			_parser.finish();	
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

			trace("tag " + flvts);
			_handler(flvts, tag);
		}

		private var ppsList:Vector.<ByteArray>;
		private var spsList:Vector.<ByteArray>;
		
		private function sortSPS(a:ByteArray, b:ByteArray):int
		{
			var ourEg:ExpGolomb = new ExpGolomb(a);
			ourEg.readBits(8);
            ourEg.readBits(20);
			var Id_a:int = ourEg.readUE();

			ourEg = new ExpGolomb(b);
			ourEg.readBits(8);
            ourEg.readBits(20);
			var Id_b:int = ourEg.readUE();

			return Id_a - Id_b;
		}

		private function sortPPS(a:ByteArray, b:ByteArray):int
		{
			var ourEg:ExpGolomb = new ExpGolomb(a);
			ourEg.readBits(8);
			var Id_a:int = ourEg.readUE();

			ourEg = new ExpGolomb(b);
			ourEg.readBits(8);
			var Id_b:int = ourEg.readUE();

			return Id_a - Id_b;			
		}

		private function makeAVCC():ByteArray
		{
			if( !_sps || !_pps)
				return null;
			
			// Some sanity checking, easier than special casing loops.
			if(ppsList == null)
				ppsList = new Vector.<ByteArray>();
			if(spsList == null)
				spsList = new Vector.<ByteArray>();

			var avcc:ByteArray = new ByteArray();
			var cursor:uint = 0;
			   
			avcc[cursor++] = 0x00; // stream ID
			avcc[cursor++] = 0x00;
			avcc[cursor++] = 0x00;

			avcc[cursor++] = 0x01; // version
			avcc[cursor++] = _sps[1]; // profile
			avcc[cursor++] = _sps[2]; // compatiblity
			avcc[cursor++] = _sps[3]; // level
			avcc[cursor++] = 0xFC | 3; // nalu marker length size - 1, we're using 4 byte ints.
			avcc[cursor++] = 0xE0 | spsList.length; // reserved bit + SPS count

			spsList.sort(sortSPS);

			for(var i:int=0; i<spsList.length; i++)
			{
				// Debug dump the SPS
				var spsLength:uint = spsList[i].length;

				trace("SPS #" + i + " profile " + spsList[i][1] + "   " + Hex.fromArray(spsList[i], true));

				var eg:ExpGolomb = new ExpGolomb(spsList[i]);
				eg.readBits(8);
	            eg.readBits(20);
	            trace("Saw id " + eg.readUE());

				avcc.position = cursor;
				spsList[i].position = 0;
				avcc.writeShort(spsLength);
				avcc.writeBytes(spsList[i], 0, spsLength);
				cursor += spsLength + 2;
			}
			
			avcc[cursor++] = ppsList.length; // encode PPSes

			ppsList.sort(sortPPS);

			for(i=0; i<ppsList.length; i++)
			{
				var ppsLength:uint = ppsList[i].length;
				trace("PPS length #" + i + " is " + ppsLength + "   " + Hex.fromArray(ppsList[i], true));

				eg = new ExpGolomb(ppsList[i]);
				eg.readBits(8);
	            trace("Saw id " + eg.readUE());

				avcc.position = cursor;
				ppsList[i].position = 0;
				avcc.writeShort(ppsLength);
				avcc.writeBytes(ppsList[i], 0, ppsLength);
				cursor += ppsLength + 2;
			}

			return avcc;
		}
		
		private static var avcTemp:ByteArray = new ByteArray();

		/**
		 * Append AVC data for FLV packet.
		 *
		 * @returns NALU data with emulation bytes removed.
		 */
		private function appendAVCNALU(bytes:ByteArray, cursor:uint, length:uint):ByteArray
		{
			// Copy into a temp buffer excluding any emulation bytes.
			avcTemp.length = avcTemp.position = 0;
			for(var i:int=cursor; i<cursor+length; i++)
			{
				if(bytes[i] == 0x03 && (i-cursor) >= 3)
				{
					if(bytes[i-1] == 0x00 && bytes[i-2] == 0x00)
					{
						trace("SKIPPING EMULATION BYTE @ " + i);
						continue;
					}
				}

				avcTemp.writeByte(bytes[i]);
			}

			if(avcTemp.length != length)
				trace("Got real length " + avcTemp.length + " vs proposed length " + length);

			if(accumulateParams == false)
			{
				_avcPacket.writeUnsignedInt(avcTemp.length);
				_avcPacket.writeBytes(avcTemp, 0, avcTemp.length);				
			}

			return avcTemp;
		}

		private var onlySendFirstSegmentAVCCFlag:Boolean = false;

		public function flushPPS():void
		{
			trace("Flushing PPS flag and set");
			onlySendFirstSegmentAVCCFlag = false;
			ppsList = new Vector.<ByteArray>();
			spsList = new Vector.<ByteArray>();
		}

		// We can reuse this to save on allocations.
		public static var flvGenerationBuffer:ByteArray = new ByteArray();

		private function sendCompleteAVCFLVTag(pts:Number, dts:Number):void
		{
			var flvts:uint = convertFLVTimestamp(dts);
			var tsu:uint = convertFLVTimestamp(pts - dts);
			flvGenerationBuffer.length = 0;
			flvGenerationBuffer.position = 0;
			
			//trace("pts = " + pts + " dts = " + dts + " tsu = " + tsu + " V");

			if( pts < 0 || dts < 0)
				return;
			
			if(_sendAVCC == true && onlySendFirstSegmentAVCCFlag == false)
			{
				trace("Attempting to send AVCC");
				var avcc:ByteArray = makeAVCC();
				if(avcc)
				{
					trace("SENDING AVCC");
					sendFLVTag(flvts, FLVTags.TYPE_VIDEO, FLVTags.VIDEO_CODEC_AVC_KEYFRAME, FLVTags.AVC_MODE_AVCC, avcc, 0, avcc.length);
					_sendAVCC = false;

					if(!isBestEffort)
						onlySendFirstSegmentAVCCFlag = true;
				}
			}
			
			if(_avcPacket.length == 0)
				return;

			var codec:uint;
			if(_keyFrame)
				codec = FLVTags.VIDEO_CODEC_AVC_KEYFRAME;
			else
				codec = FLVTags.VIDEO_CODEC_AVC_PREDICTIVEFRAME;
			
			flvGenerationBuffer.length = 3 + _avcPacket.length;
			flvGenerationBuffer[0] = (tsu >> 16) & 0xff;
			flvGenerationBuffer[1] = (tsu >>  8) & 0xff;
			flvGenerationBuffer[2] = (tsu      ) & 0xff;
			flvGenerationBuffer.position = 3;
			flvGenerationBuffer.writeBytes(_avcPacket);
			dumpBytes("[AVC] ", flvGenerationBuffer, 0, flvGenerationBuffer.length);
			_avcPacket.length = 0;
			
			sendFLVTag(flvts, FLVTags.TYPE_VIDEO, codec, FLVTags.AVC_MODE_PICTURE, flvGenerationBuffer, 0, flvGenerationBuffer.length);
		}
		
		private function setAVCSPS(bytes:ByteArray, cursor:uint, length:uint):void
		{
			_sps = new ByteArray;
			_sps.writeBytes(bytes, cursor, length);
			_sendAVCC = true;

			var ourEg:ExpGolomb = new ExpGolomb(_sps);
			ourEg.readBits(8);
			ourEg.readBits(20);
			var ourId:int = ourEg.readUE();

			// If not present in list add it!
			var found:Boolean = false;
			for(var i:int=0; i<spsList.length; i++)
			{
				// If it matches our ID, replace it.
				var eg:ExpGolomb = new ExpGolomb(spsList[i]);
				eg.readBits(8);
				eg.readBits(20);
				var foundId:int = eg.readUE();

				if(foundId == ourId)
				{
					trace("Got SPS match for " + foundId + "!");
					spsList[i] = _sps;
					return;
				}

				if(spsList[i].length != length)
					continue;

				for(var j:int=0; j<spsList[i].length && j<_sps.length; j++)
					if(spsList[i][j] != _sps[j])
						continue;

				found = true;
				break;
			}

			if(!found)
				spsList.push(_sps);
		}
		
		private function setAVCPPS(bytes:ByteArray, cursor:uint, length:uint):void
		{
			_pps = new ByteArray;
			_pps.writeBytes(bytes, cursor, length);
			_sendAVCC = true;

			var ourEg:ExpGolomb = new ExpGolomb(_pps);
			ourEg.readBits(8);
			var ourId:int = ourEg.readUE();

			// If not present in list add it!
			var found:Boolean = false;
			for(var i:int=0; i<ppsList.length; i++)
			{
				// If it matches our ID, replace it.
				var eg:ExpGolomb = new ExpGolomb(ppsList[i]);
				eg.readBits(8);
				var foundId:int = eg.readUE();

				if(foundId == ourId)
				{
					trace("Got PPS match for " + foundId + "!");
					ppsList[i] = _pps;
					return;
				}

				if(ppsList[i].length != length)
					continue;

				for(var j:int=0; j<ppsList[i].length && j<_pps.length; j++)
					if(ppsList[i][j] != _pps[j])
						continue;

				found = true;
				break;
			}

			if(!found)			
				ppsList.push(_pps);
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

		public function onAVCNALU(pts:Number, dts:Number, bytes:ByteArray, cursor:uint, length:uint):void
		{
			// What's the type?
			var naluType:uint = bytes[cursor] & 0x1f;

			//trace("nalu length " + length + " type " + naluType);

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
						if(accumulateParams == false)
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

			var tmp:ByteArray;
			
			switch(naluType)
			{
				case 0x07: // SPS
					trace("Grabbing AVC SPS length=" + length);
					tmp = appendAVCNALU(bytes, cursor, length);
					setAVCSPS(tmp, 0, tmp.length);
					break;
				
				case 0x08: // PPS
					trace("Grabbing AVC PPS length=" + length);
					tmp = appendAVCNALU(bytes, cursor, length);
					setAVCPPS(tmp, 0, tmp.length);
					break;
				
				case 0x09: // "access unit delimiter"
					switch((bytes[cursor + 1] >> 5) & 0x07) // access unit type
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
					break;

				default:
					// Infer keyframe state.
					if(naluType == 5)
						_keyFrame = true;
					else if(naluType == 1)
						_keyFrame = false;
					
					// Process more NALU; skipping the start code.
					appendAVCNALU(bytes, cursor, length);
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