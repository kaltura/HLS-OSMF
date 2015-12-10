package 
{
    import flash.utils.ByteArray;
    import flash.net.ObjectEncoding;
    import flash.utils.ByteArray;
    import flash.utils.Endian;    
    import flash.utils.IDataInput;
    import flash.utils.IDataOutput;

    /**
     * Responsible for emitting FLV data. Also handles AAC conversion
     * config and buffering.
     */
    public class FLVTranscoder
    {
        public const MIN_FILE_HEADER_BYTE_COUNT:int = 9;
        public var output:ByteArray = new ByteArray();
        
        private var _aacConfig:ByteArray;
        private var _aacRemainder:ByteArray;
        private var _aacTimestamp:Number;

        public function clear(clearAACConfig:Boolean = false):void
        {
            if(clearAACConfig)
                _aacConfig = null;
            _aacRemainder = null;
            _aacTimestamp = 0;
        }

        public function writeHeader(hasAudio:Boolean, hasVideo:Boolean):void
        {
            output.writeByte(0x46); // 'F'
            output.writeByte(0x4c); // 'L'
            output.writeByte(0x56); // 'V'
            output.writeByte(0x01); // version 0x01
            
            var flags:uint = 0;
            if (hasAudio)
                flags |= 0x04;
            if (hasVideo)
                flags |= 0x01;
            
            output.writeByte(flags);            
            output.writeUnsignedInt(0x09);
            output.writeUnsignedInt(0);
        }

        private static var tag:ByteArray = new ByteArray();

        private function sendFLVTag(flvts:uint, type:uint, codec:int, mode:int, bytes:ByteArray, offset:uint, length:uint):void
        {
            tag.position = 0;
            var msgLength:uint = length + ((codec >= 0) ? 1 : 0) + ((mode >= 0) ? 1 : 0);
            var cursor:uint = 0;
            
            if(msgLength > 0xffffff)
                return; // too big for the length field
        
            tag.length = FLVTags.HEADER_LENGTH + msgLength; 

            trace("FLV @ " + flvts + " len=" + tag.length + " type=" + type);

            tag[cursor++] = type;
            tag[cursor++] = (msgLength >> 16) & 0xff;
            tag[cursor++] = (msgLength >>  8) & 0xff;
            tag[cursor++] = (msgLength      ) & 0xff;
            tag[cursor++] = (flvts >> 16) & 0xff;
            tag[cursor++] = (flvts >>  8) & 0xff;
            tag[cursor++] = (flvts      ) & 0xff;
            tag[cursor++] = (flvts >> 24) & 0xff;
            tag[cursor++] = 0x00; // stream ID
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

            // Append tag.
            output.writeBytes(tag, 0, tag.length);
            output.writeUnsignedInt(tag.length);
        }

        public function convertFLVTimestamp(pts:Number):Number 
        {
            return pts / 90.0;
        }

        private static var flvGenerationBuffer:ByteArray = new ByteArray();

        public function emitSPSPPS(unit:NALU):void
        {
            // Cheat for transcoder.
            writeHeader(true, true);

            var avcc:ByteArray = NALUProcessor.serializeAVCC();
            if(!avcc)
            {
                trace("Failed to emit AVCC!");
                return;
            }
            
            sendFLVTag(convertFLVTimestamp(unit.pts), FLVTags.TYPE_VIDEO, FLVTags.VIDEO_CODEC_AVC_KEYFRAME, FLVTags.AVC_MODE_AVCC, avcc, 0, avcc.length);
        }

        /**
         * Convert and amit AVC NALU data.
         */
        public function convert(unit:NALU):void
        {
            var flvts:uint = convertFLVTimestamp(unit.dts);
            var tsu:uint = convertFLVTimestamp(unit.pts - unit.dts);

            // Accumulate NALUs into buffer.
            flvGenerationBuffer.length = 3;
            flvGenerationBuffer[0] = (tsu >> 16) & 0xff;
            flvGenerationBuffer[1] = (tsu >>  8) & 0xff;
            flvGenerationBuffer[2] = (tsu      ) & 0xff;
            flvGenerationBuffer.position = 3;

            // Check keyframe status.
            var keyFrame:Boolean = false;
            var totalAppended:int = 0;
            NALUProcessor.walkNALUs(unit.buffer, 0, function(bytes:ByteArray, cursor:uint, length:uint):void
            {
                // Check for a NALU that is keyframe type.
                var naluType:uint = bytes[cursor] & 0x1f;
                //trace(naluType + " length=" + length);
                switch(naluType)
                {
                    case 0x09: // "access unit delimiter"
                        switch((bytes[cursor + 1] >> 5) & 0x07) // access unit type
                        {
                            case 0:
                            case 3:
                            case 5:
                                keyFrame = true;
                                break;
                            default:
                                keyFrame = false;
                                break;
                        }
                        break;

                    default:
                        // Infer keyframe state.
                        if(naluType == 5)
                            keyFrame = true;
                        else if(naluType == 1)
                            keyFrame = false;                        
                }

                // Skip any non VCL NALUs.
                if(naluType == 7 || naluType == 8)
                    return;

                // Append.
                flvGenerationBuffer.writeUnsignedInt(length);
                flvGenerationBuffer.writeBytes(bytes, cursor, length);
                totalAppended += length;
            }, true );

            var codec:uint;
            if(keyFrame)
                codec = FLVTags.VIDEO_CODEC_AVC_KEYFRAME;
            else
                codec = FLVTags.VIDEO_CODEC_AVC_PREDICTIVEFRAME;

            //trace("ts=" + flvts + " tsu=" + tsu + " keyframe = " + keyFrame);
            
            sendFLVTag(flvts, FLVTags.TYPE_VIDEO, codec, FLVTags.AVC_MODE_PICTURE, flvGenerationBuffer, 0, flvGenerationBuffer.length);
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

        /**
         * Convert and amit AAC data.
         */
        public function convertAAC(pes:PESPacket):void
        {
            var timeAccumulation:Number = 0.0;
            var limit:uint;
            var stream:ByteArray;
            var hadRemainder:Boolean = false;
            var cursor:int = pes.headerLength;
            var length:int = pes.buffer.length - pes.headerLength;
            var bytes:ByteArray = pes.buffer;
            var timestamp:Number = pes.pts;
            
            trace("pes pts = " + pes.pts + " headerLength = " + headerLength);

            if(_aacRemainder)
            {
                stream = _aacRemainder;
                stream.writeBytes(bytes, cursor, length);
                cursor = 0;
                length = stream.length;
                _aacRemainder = null;
                hadRemainder = true;
                timeAccumulation = _aacTimestamp - timestamp;
                trace("remainder " + stream.length);
            }
            else
                stream = bytes;
            
            limit = cursor + length;
            
            // an AAC PES packet can contain multiple ADTS frames
            var eaten:int = 0;
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
                if(stream[cursor] != 0xff)
                {
                    trace("Missed sync word " + stream[cursor]);
                    eaten++;
                    cursor++;
                    continue;
                }

                // One of three possibilities...
                //   0xF1 = MPEG 4, layer 0, no CRC
                //   0xF8 = MPEG 2, layer 0, CRC
                //   0xF9 = MPEG 2, layer 0, no CRC
                trace("stream[cursor+1] = " + stream[cursor+1]);
                if(stream[cursor+1] != 0xF1 
                    && stream[cursor+1] != 0xF8 
                    && stream[cursor+1] != 0xF9)
                {
                    trace("ATE");
                    eaten++;
                    cursor++;
                    continue;                    
                }
                
                if(eaten > 0)
                {
                    trace("ATE " + eaten + " bytes to find sync!");
                    eaten = 0;
                }
                
                // Check for protection absent bit, it allows us to handle CRC.
                var hasProtection:Boolean = false;
                trace("stream[cursor+1] 2 = " + stream[cursor+1]);
                if(stream[cursor + 1] & 0x1)
                {
                    hasProtection = true;
                }

                var headerLength:int = FLVTags.ADTS_FRAME_HEADER_LENGTH + (hasProtection ? 2 : 0);

                // Determine expected length
                frameLength  = (stream[cursor + 3] & 0x03) << 11;
                frameLength += (stream[cursor + 4]) << 3;
                frameLength += (stream[cursor + 5] >> 5) & 0x07;

                trace("Expecting length of " + frameLength + " hasProtection = " + hasProtection);
                
                // Check for an invalid ADTS header; if so look for next syncword.
                if(frameLength < headerLength)
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
                    trace("Sending AAC @ " + flvts + " ts=" + timestamp + " acc=" + timeAccumulation + " frameLen=" + frameLength + " sampleRate = " + sampleRate);
                    sendFLVTag(flvts, FLVTags.TYPE_AUDIO, FLVTags.AUDIO_CODEC_AAC, FLVTags.AAC_MODE_FRAME, stream, cursor + headerLength, frameLength - headerLength);
                    
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
                trace("AAC timestamp was " + _aacTimestamp);
                _aacRemainder = new ByteArray();
                _aacRemainder.writeBytes(stream, cursor, limit - cursor);
                _aacTimestamp = timestamp + timeAccumulation;
                trace("AAC timestamp now " + _aacTimestamp + " remainder=" + _aacRemainder.length);
            }            
        }

        /**
         * Convert and emit MP3 data.
         */
        public function convertMP3(pes:PESPacket):void
        {
            sendFLVTag(convertFLVTimestamp(pes.pts), FLVTags.TYPE_AUDIO, FLVTags.AUDIO_CODEC_MP3, -1, pes.buffer, 0, pes.buffer.length);
        }
    }


    /**
     * NALU processing utilities.
     */
    public class NALUProcessor
    {
        private static var ppsList:Vector.<ByteArray> = new Vector.<ByteArray>;
        private static var spsList:Vector.<ByteArray> = new Vector.<ByteArray>;
        
        private static function sortSPS(a:ByteArray, b:ByteArray):int
        {
            var ourEg:ExpGolomb = new ExpGolomb(a);
            ourEg.readBits(8);
            ourEg.readBits(24);
            var Id_a:int = ourEg.readUE();

            ourEg = new ExpGolomb(b);
            ourEg.readBits(8);
            ourEg.readBits(24);
            var Id_b:int = ourEg.readUE();

            return Id_a - Id_b;
        }

        private static function sortPPS(a:ByteArray, b:ByteArray):int
        {
            var ourEg:ExpGolomb = new ExpGolomb(a);
            ourEg.readBits(8);
            var Id_a:int = ourEg.readUE();

            ourEg = new ExpGolomb(b);
            ourEg.readBits(8);
            var Id_b:int = ourEg.readUE();

            return Id_a - Id_b;         
        }

        /**
         * Actually perform serialization of the AVCC.
         */
        public static function serializeAVCC():ByteArray
        {            
            // Some sanity checking, easier than special casing loops.
            if(ppsList == null)
                ppsList = new Vector.<ByteArray>();
            if(spsList == null)
                spsList = new Vector.<ByteArray>();

            if(ppsList.length == 0 || spsList.length == 0)
                return null;

            var avcc:ByteArray = new ByteArray();
            var cursor:uint = 0;
               
            avcc[cursor++] = 0x00; // stream ID
            avcc[cursor++] = 0x00;
            avcc[cursor++] = 0x00;

            avcc[cursor++] = 0x01; // version
            avcc[cursor++] = spsList[0][1]; // profile
            avcc[cursor++] = spsList[0][2]; // compatiblity
            avcc[cursor++] = spsList[0][3]; // level
            avcc[cursor++] = 0xFC | 3; // nalu marker length size - 1, we're using 4 byte ints.
            avcc[cursor++] = 0xE0 | spsList.length; // reserved bit + SPS count

            spsList.sort(sortSPS);

            for(var i:int=0; i<spsList.length; i++)
            {
                // Debug dump the SPS
                var spsLength:uint = spsList[i].length;

                trace("SPS #" + i + " " + Hex.fromArray(spsList[i], true));

                var eg:ExpGolomb = new ExpGolomb(spsList[i]);
                eg.readBits(8);
                eg.readBits(24);
                trace("Saw id " + eg.readUE());

                avcc.position = cursor;
                spsList[i].position = 0;
                avcc.writeShort(spsLength);
                avcc.writeBytes(spsList[i], 0, spsLength);
                cursor += spsLength + 2;
            }
            
            avcc[cursor++] = ppsList.length; // PPS count.

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

        /**
         * Update our internal list of SPS entries, merging as needed.
         */
        private static function setAVCSPS(bytes:ByteArray, cursor:uint, length:uint):void
        {
            var sps:ByteArray = new ByteArray();
            sps.writeBytes(bytes, cursor, length);

            var ourEg:ExpGolomb = new ExpGolomb(sps);
            ourEg.readBits(8);
            ourEg.readBits(24);
            var ourId:int = ourEg.readUE();

            //trace("Saw potential SPS " + ourId + " " + Hex.fromArray(sps, true));

            // If not present in list add it!
            for(var i:int=0; i<spsList.length; i++)
            {
                // If it matches our ID, replace it.
                var eg:ExpGolomb = new ExpGolomb(spsList[i]);
                eg.readBits(8);
                eg.readBits(24);
                var foundId:int = eg.readUE();

                if(foundId != ourId)
                    continue;

                //trace("Got SPS match for " + foundId + "!");
                spsList[i] = sps;
                return;
            }

            // Maybe we do have to add it!
            spsList.push(sps);
        }

        /**
         * Update our internal list of PPS entries, merging as needed.
         */
        private static function setAVCPPS(bytes:ByteArray, cursor:uint, length:uint):void
        {
            var pps:ByteArray = new ByteArray;
            pps.writeBytes(bytes, cursor, length);

            var ourEg:ExpGolomb = new ExpGolomb(pps);
            ourEg.readBits(8);
            var ourId:int = ourEg.readUE();

            //trace("Saw potential PPS " + ourId + " " + Hex.fromArray(pps, true));

            // If not present in list add it!
            for(var i:int=0; i<ppsList.length; i++)
            {
                // If it matches our ID, replace it.
                var eg:ExpGolomb = new ExpGolomb(ppsList[i]);
                eg.readBits(8);
                var foundId:int = eg.readUE();

                if(foundId != ourId)
                    continue;

                //trace("Got PPS match for " + foundId + "!");
                ppsList[i] = pps;
                return;
            }

            // Maybe we do have to add it!
            ppsList.push(pps);
        }        

        /**
         * Given a buffer containing NALUs, walk through them and call callback
         * with the extends of each. It's given in order the buffer, start, and 
         * length of each found NALU.
         */
        public static function walkNALUs(bytes:ByteArray, cursor:int, callback:Function, flushing:Boolean = false):void
        {
            var originalStart:int = int(cursor);
            var start:int = int(cursor);
            var end:int;
            var naluLength:uint;

            start = NALU.scan(bytes, start, false);
            while(start >= 0)
            {
                end = NALU.scan(bytes, start, true);

                if(end >= 0)
                {
                    naluLength = end - start;
                }
                else if(flushing)
                {
                    naluLength = bytes.length - start;
                }
                else
                {
                    break;
                }
                
                //var tmpBytes:ByteArray = stripEmulationBytes(bytes, uint(start), naluLength);

                callback(bytes, uint(start), naluLength);
                //callback(tmpBytes, 0, tmpBytes.length);
                
                cursor = start + naluLength;
                start = NALU.scan(bytes, cursor, false);
            }
        }

        /**
         * NALUs use 0x000001 to indicate start codes. However, data may need
         * to contain this code. In this case an 0x03 is inserted to break up
         * the start code pattern. This function strips such bytes.
         */
        public static function stripEmulationBytes(buffer:ByteArray, cursor:uint, length:uint):ByteArray
        {
            var tmp:ByteArray = new ByteArray();
            for(var i:int=cursor; i<cursor+length; i++)
            {
                if(buffer[i] == 0x03 && (i-cursor) >= 3)
                {
                    if(buffer[i-1] == 0x00 && buffer[i-2] == 0x00)
                    {
                        //trace("SKIPPING EMULATION BYTE @ " + i);
                        continue;
                    }
                }

                tmp.writeByte(buffer[i]);
            }

            tmp.position = 0;
            return tmp;
        }

        private static function extractAVCCInner(bytes:ByteArray, cursor:uint, length:uint):void
        {
            // What's the type?
            var naluType:uint = bytes[cursor] & 0x1f;
            //trace("nalu " + naluType + " len=" + length);
            if(naluType == 7)
            {
                // Handle SPS
                var spsStripped:ByteArray = stripEmulationBytes(bytes, cursor, length);
                //setAVCSPS(spsStripped, 0, spsStripped.length);
                setAVCSPS(bytes, cursor, length);
            }
            else if(naluType == 8)
            {
                // Handle PPS
                var ppsStripped:ByteArray = stripEmulationBytes(bytes, cursor, length);
                //setAVCPPS(ppsStripped, 0, ppsStripped.length );
                setAVCPPS(bytes, cursor, length);
            }
        }

        public static function startAVCCExtraction():void
        {
            spsList = new Vector.<ByteArray>();
            ppsList = new Vector.<ByteArray>();            
        }

        public static function pushAVCData(unit:NALU):void
        {
            // Go through each buffer and find all the SPS/PPS info.
            walkNALUs(unit.buffer, 0, extractAVCCInner, true)
        }
    }

    /**
     * Represents a block of NALUs from a given time period in the file.
     */
    public class NALU
    {
        public var pts:Number, dts:Number;
        public var buffer:ByteArray;

        public var type:int;

        public function clone():NALU
        {
            var tmpBuffer:ByteArray = new ByteArray();
            tmpBuffer.writeBytes(buffer);

            var p:NALU = new NALU();
            p.type = type;
            p.pts = pts;
            p.dts = dts;
            p.buffer = tmpBuffer;
            return p;
        }

        /**
         * Scan buffer for NALU start code.
         *
         * @param cursor Start at cursor bytes in buffer.
         * @param bytes  Buffer to scan for start codes.
         * @param beginning If true, return the offset of the start of the code; if false, offset immediately following it.
         */
        public static function scan(bytes:ByteArray, cursor:int, beginning:Boolean):int
        {
            var curPos:int;
            var length:int = bytes.length - 3;
            
            for(curPos = cursor; curPos < length; curPos++)
            {
                // First two bytes should be 0, skip if not.
                if(    bytes[curPos  ] != 0x00
                    || bytes[curPos+1] != 0x00)
                    continue;

                // Three byte marker.
                if(bytes[curPos + 2] == 0x01)
                {
                    //trace("3 byte");
                    return curPos + (beginning ? 0 : 3);
                } 
                // Four byte marker (but return from 2nd byte as we assume 3 byte elsewhere)
                else if( curPos + 1 < length
                    && (bytes[curPos + 2] == 0x00)
                    && (bytes[curPos + 3] == 0x01))
                {
                    //trace("4 byte");
                    return curPos + (beginning ? 0 : 4);
                }
            }
            
            return -1;
        }        
    }

    /**
     * Helper for processing PES streams.
     */
    public class PESPacketStream
    {
        public function PESPacketStream()
        {
            buffer = new ByteArray();
            _shiftBuffer = new ByteArray();
        }

        public function append(bytes:ByteArray, cursor:int):void
        {
            buffer.position = buffer.length;
            buffer.writeBytes(bytes, cursor, bytes.length - cursor);
        }
        
        /**
         * Drop bytes from the left of the PES packet stream buffer.
         */
        public function shiftLeft(num:int):void
        {
            var newLength:int = buffer.length - num;
            var tmpBytes:ByteArray;
            
            _shiftBuffer.length = newLength;
            _shiftBuffer.position = 0;
            _shiftBuffer.writeBytes(buffer, num, newLength);
            
            tmpBytes = buffer;
            buffer = _shiftBuffer;
            _shiftBuffer = tmpBytes;
        }
        
        public var buffer:ByteArray;
        public var pts:Number;
        public var dts:Number;

        public var headerLength:int = NaN;
        
        // We swap back and forth to avoid allocations.
        private var _shiftBuffer:ByteArray;
    }

    /**
     * Process packetized elementary streams and extract NALUs and other data.
     */
    public class PESProcessor
    {
        public var types:Object = {};
        public var streams:Object = {};

        public var lastVideoNALU:NALU = null;

        public var transcoder:FLVTranscoder = new FLVTranscoder();

        public var headerSent:Boolean = false;

        public var pmtStreamId:int = -1;

        public function logStreams():void
        {
            trace("----- PES state -----");
            for(var k:* in streams)
            {
                trace("   " + k + " has " + streams[k].buffer.length + " bytes, type=" + types[k]);
            }
        }

        public function clear(clearAACConfig:Boolean = true):void
        {
            streams = {};
            lastVideoNALU = null;
            transcoder.clear(clearAACConfig);
        }

        private function parseProgramAssociationTable(bytes:ByteArray, cursor:uint):Boolean
        {
            // Get the section length.
            var sectionLen:uint = ((bytes[cursor+2] & 0x03) << 8) | bytes[cursor+3];

            // Check the section length for a single PMT.
            if (sectionLen > 13)
                trace("Saw multiple PMT entries in the PAT; blindly choosing first one.");

            // Grab the PMT ID.
            pmtStreamId = ((bytes[cursor+10] << 8) | bytes[cursor+11]) & 0x1FFF;
            trace("Saw PMT ID of " + pmtStreamId);

            return true;
        }

        private function parseProgramMapTable(bytes:ByteArray, cursor:uint):Boolean
        {
            var sectionLength:uint;
            var sectionLimit:uint;
            var programInfoLength:uint;
            var type:uint;
            var pid:uint;
            var esInfoLength:uint;
            var seenPIDsByClass:Array;
            var mediaClass:int;

            var hasAudio:Boolean = false, hasVideo:Boolean = false;

            // Set up types.
            types = [];
            seenPIDsByClass = [];
            seenPIDsByClass[MediaClass.VIDEO] = Infinity;
            seenPIDsByClass[MediaClass.AUDIO] = Infinity;
            
            // Process section length and limit.
            cursor++;
            
            sectionLength = ((bytes[cursor] & 0x0f) << 8) + bytes[cursor + 1];
            cursor += 2;

            if(sectionLength + cursor > bytes.length)
            {
                trace("Not enough data to read. 1");
                return false;
            }
            
            // Skip a few things we don't care about: program number, RSV, version, CNI, section, last_section, pcr_cid
            sectionLimit = cursor + sectionLength;          
            cursor += 7;
            
            // And get the program info length.
            programInfoLength = ((bytes[cursor] & 0x0f) << 8) + bytes[cursor + 1];
            cursor += 2;
            
            // If not enough data to proceed, bail.
            if(programInfoLength + cursor > bytes.length)
            {
                trace("Not enough data to read. 2");
                return false;
            }

            cursor += programInfoLength;
                        
            const CRC_SIZE:int = 4;
            while(cursor < sectionLimit - CRC_SIZE)
            {
                type = bytes[cursor++];
                pid = ((bytes[cursor] & 0x1f) << 8) + bytes[cursor + 1];
                cursor += 2;
                
                mediaClass = MediaClass.calculate(type);
                
                if(mediaClass == MediaClass.VIDEO)
                {
                    trace("VIDEO is " + pid);
                    hasVideo = true;
                }

                if(mediaClass == MediaClass.AUDIO)
                {
                    trace("AUDIO is " + pid);                    
                    hasAudio = true;
                }

                // For video & audio, select the lowest PID for each kind.
                if(mediaClass == MediaClass.OTHER
                 || pid < seenPIDsByClass[mediaClass]) 
                {
                    // Clear a higher PID if present.
                    if(mediaClass != MediaClass.OTHER
                     && seenPIDsByClass[mediaClass] < Infinity)
                        types[seenPIDsByClass[mediaClass]] = -1;
                    
                    types[pid] = type;
                    seenPIDsByClass[mediaClass] = pid;
                }
                
                // Skip the esInfo data.
                esInfoLength = ((bytes[cursor] & 0x0f) << 8) + bytes[cursor + 1];
                cursor += 2;
                cursor += esInfoLength;
            }

            // Cook out header to transcoder.
            //transcoder.writeHeader(hasAudio, hasVideo);
            headerSent = true;
            
            return true;
        }

        public function append(packet:PESPacket):void
        {
            var b:ByteArray = packet.buffer;
            b.position = 0;

            if(b.length < 8)
            {
                trace("Ignoring too short PES packet, length=" + b.length);
                return;
            }

            // Get the start code.
            var startCode:uint = b.readUnsignedInt();
            if((startCode & 0xFFFFFF00) != 0x00000100)
            {
                // It could be a program association table.
                if((startCode & 0xFFFFFF00) == 0x0000b000)
                {
                    parseProgramAssociationTable(b, 1);
                    return;
                }

                // It could be the program map table.
                if((startCode & 0xFFFFFC00) == 0x0002b000)
                {
                    trace("GOT PMT");
                    parseProgramMapTable(b, 1);
                    return;
                }

                var tmp:ByteArray = new ByteArray();
                tmp.writeInt(startCode);
                trace("ES prefix was wrong, expected 00:00:01:xx but got "); // + Hex.fromArray(tmp, true));
                return;
            }

            // Get the stream ID.
            var streamID:int = startCode & 0xFF;

            // Get the length.
            var packetLength:uint = b.readUnsignedShort();
            if(packetLength)
            {
                if(b.length < packetLength )
                {
                    trace("WARNING: parsePESPacket - not enough bytes, expecting " + packetLength + ", but have " + b.length);
                    return; // not enough bytes in packet
                }
            }
            
            if(b.length < 9)
            {
                trace("WARNING: parsePESPacket - too short to read header!");
                return;
            }

            // Read the rest of the header.
            var cursor:uint = 6;
            var dataAlignment:Boolean = (b[cursor] & 0x04) != 0;
            cursor++;
            
            var ptsDts:uint = (b[cursor] & 0xc0) >> 6;
            cursor++;
            
            var pesHeaderDataLength:uint = b[cursor];
            cursor++;

            //trace(" PES align=" + dataAlignment + " ptsDts=" + ptsDts + " header=" + pesHeaderDataLength);

            var pts:Number = 0, dts:Number = 0;
            
            if(ptsDts & 0x02)
            {
                // has PTS at least
                if(cursor + 5 > b.length)
                    return;
                
                pts  = b[cursor] & 0x0e;
                pts *= 128;
                pts += b[cursor + 1];
                pts *= 256;
                pts += b[cursor + 2] & 0xfe;
                pts *= 128;
                pts += b[cursor + 3];
                pts *= 256;
                pts += b[cursor + 4] & 0xfe;
                pts /= 2;
                
                if(ptsDts & 0x01)
                {
                    // DTS too!
                    if(cursor + 10 > b.length)
                        return;
                    
                    dts  = b[cursor + 5] & 0x0e;
                    dts *= 128;
                    dts += b[cursor + 6];
                    dts *= 256;
                    dts += b[cursor + 7] & 0xfe;
                    dts *= 128;
                    dts += b[cursor + 8];
                    dts *= 256;
                    dts += b[cursor + 9] & 0xfe;
                    dts /= 2;
                }
                else
                    dts = pts;
            }

            packet.pts = pts;
            packet.dts = dts;
            //trace("   PTS=" + pts/90000 + " DTS=" + dts/90000);

            cursor += pesHeaderDataLength;
            
            if(cursor > b.length)
            {
                trace("WARNING: parsePESPacket - ran out of bytes");
                return;
            }
            
            if(types[packet.packetID] == undefined)
            {
                trace("WARNING: parsePESPacket - unknown type");
                return;
            }
            
            var pes:PESPacketStream;

            if(streams[packet.packetID] == undefined)
            {
                if(dts < 0.0)
                {
                    trace("WARNING: parsePESPacket - invalid decode timestamp, skipping");
                    return;
                }
                
                pes = new PESPacketStream();
                streams[packet.packetID] = pes;
            }
            else
            {
                pes = streams[packet.packetID];
            }
            
            pes.headerLength = cursor;
            packet.headerLength = cursor;

            if(headerSent == false)
            {
                trace("Skipping data that came before PMT");
                return;
            }

            // Note the type at this moment in time.
            packet.type = types[packet.packetID];

            // And process.
            if(MediaClass.calculate(types[packet.packetID]) == MediaClass.VIDEO)
            {
                var start:int = NALU.scan(b, cursor, true);
                if(start == -1 && lastVideoNALU)
                {
                    trace("Stuff entire " + (b.length - cursor) + " into previous NALU.");
                    lastVideoNALU.buffer.position = lastVideoNALU.buffer.length;
                    b.position = 0;
                    lastVideoNALU.buffer.writeBytes(b, cursor, b.length - cursor);
                    return;

                }
                else if((start - cursor) > 0 && lastVideoNALU)
                {
                    // Shove into previous buffer.
                    trace("Stuffing first " + (start - cursor) + " bytes into previous NALU.");
                    lastVideoNALU.buffer.position = lastVideoNALU.buffer.length;
                    b.position = 0;
                    lastVideoNALU.buffer.writeBytes(b, cursor, start - cursor);
                    cursor = start;
                }

                // Submit previous data.
                if(lastVideoNALU)
                {
                    pendingBuffers.push(lastVideoNALU.clone());
                }

                // Update NALU state.
                lastVideoNALU = new NALU();
                lastVideoNALU.buffer = new ByteArray();
                lastVideoNALU.pts = pts;
                lastVideoNALU.dts = dts;
                lastVideoNALU.type = packet.type;
                lastVideoNALU.buffer.writeBytes(b, cursor);

            }
            else if(types[packet.packetID] == 0x0F)
            {
                // It's an AAC stream.
                pendingBuffers.push(packet.clone());
            }
            else if(types[packet.packetID] == 0x03 || types[packet.packetID] == 0x04)
            {
                // It's an MP3 stream. Pass through directly.
                pendingBuffers.push(packet.clone());
            }
            else
            {
                trace("Unknown packet ID type " + types[packet.packetID] + ", ignoring (A).");
            }
        }

        var pendingBuffers:Vector.<Object> = new Vector.<Object>();

        public function processAllNalus():void
        {
            // First walk all the video NALUs and get the correct SPS/PPS
            if(pendingBuffers.length == 0)
                return;

            // Consume any unposted video NALUs.
            if(lastVideoNALU)
            {
                pendingBuffers.push(lastVideoNALU.clone());
                lastVideoNALU = null;
            }
            
            // First walk all the video NALUs and get the correct SPS/PPS
            //NALUProcessor.startAVCCExtraction();

            var firstNalu:NALU = null;

            for(var i:int=0; i<pendingBuffers.length; i++)
            {
                if(!(pendingBuffers[i] is NALU))
                    continue;

                if(!firstNalu)
                    firstNalu = pendingBuffers[i] as NALU;

                NALUProcessor.pushAVCData(pendingBuffers[i] as NALU);
            }

            // Then emit SPS/PPS
            if(firstNalu)
            {
                transcoder.emitSPSPPS(firstNalu);
            }
            else
            {
                trace("FAILED TO GET INITIAL NALU, NO SPS/PPS!");
            }

            // Sort.
            //pendingBuffers.sort(naluSortFunc);

            // Then iterate the packet again.
            for(var i:int=0; i<pendingBuffers.length; i++)
            {
                if(pendingBuffers[i] is NALU)
                {
                    transcoder.convert(pendingBuffers[i] as NALU);
                }
                else if(pendingBuffers[i] is PESPacket)
                {
                    var packet:PESPacket = pendingBuffers[i] as PESPacket;
                    if(packet.type == 0x0F)
                    {
                        // It's an AAC stream.
                        transcoder.convertAAC(packet);
                    }
                    else if(packet.type == 0x03 || packet.type == 0x04)
                    {
                        // It's an MP3 stream.
                        transcoder.convertMP3(packet);
                    }
                    else
                    {
                        trace("Unknown packet ID type " + packet.type + ", ignoring (B).");
                    }
                }
            }

            // Don't forget to clear the pending list.
            pendingBuffers.length = 0;
        }
    }

    /**
     * Packetized ES stream parser state.
     */
    public class TSPacketStream
    {
        public var buffer:ByteArray = new ByteArray();
        public var lastContinuity:int;
        public var packetID:int;

        public var finishedLast:Boolean = false;

        /**
         * Return length if it can be safely determined.
         */
        public function get packetLength():int
        {
            if(buffer.length < 6)
                return 0;

            return ((buffer[4] << 8) + buffer[5]);
        }
    }
    /**
     * An packetized elementary stream recovered from the TS.
     */
    public class PESPacket
    {
        public function PESPacket(id:int, bytes:ByteArray)
        {
            packetID = id;
            buffer = bytes;
        }

        public function clone():PESPacket
        {
            var tmpBuffer:ByteArray = new ByteArray();
            tmpBuffer.writeBytes(buffer);

            var p:PESPacket = new PESPacket(packetID, tmpBuffer);
            p.pts = pts;
            p.dts = dts;
            p.type = type;
            p.headerLength = headerLength;
            return p;
        }

        public var type:int = -1;

        public var pts:Number, dts:Number;
        public var packetID:int = -1;
        public var buffer:ByteArray = null;

        public var headerLength:int = NaN;
    }

    /**
     * Parser for MPEG 2 Transport Stream packets.
     * 
     * Responsible for converting a stream of TS packets into elementary 
     * streams ready for processing.
     */
    public class TSPacketParser
    {
        public static var logHeaders:Boolean = true;


        private var _buffer:ByteArray = new ByteArray();
        private var _streams:Object = {}; // of TSPacketStream
        private var _totalConsumed:int = 0;
        public var pesProcessor:PESProcessor = new PESProcessor();

        public function get output():ByteArray
        {
            return pesProcessor.transcoder.output;
        }

        /**
         * Accepts arbitrary chunks of bytes and extracts TS packet data.
         */
        public function appendBytes(bytes:ByteArray):void
        {
            // Append the bytes.
            _buffer.position = _buffer.length;
            _buffer.writeBytes(bytes, 0, bytes.length);
            
            // Set up parsing state.
            var cursor:uint = 0;
            var len:uint = _buffer.length;
            
            // Consume TS packets.
            while(true)
            {
                var scanCount:int = 0;
                while(cursor + 188 < len)
                {
                    if(0x47 == _buffer[cursor])  // search for TS sync byte
                        break;

                    cursor++;
                    scanCount++;
                }

                if(scanCount > 0)
                    trace("WARNING: appendBytes - skipped " + scanCount + " bytes to sync point.");
                
                // Confirm we have something to read.
                if(!(cursor + 188 < len))
                    break;
                
                parseTSPacket(cursor);
                
                // Advance counters.
                cursor += 188;
                _totalConsumed += cursor;
            }

            // Shift remainder into beginning of buffer and try again later.
            if(cursor > 0)
            {
                var remainder:uint = _buffer.length - cursor;
                _buffer.position = 0;
                _buffer.writeBytes(_buffer, cursor, remainder);
                _buffer.length = remainder;
            }
        }

        protected function parseTSPacket(cursor:int):void
        {
            var headerLength:uint = 4;
            var payloadLength:uint;
            var discontinuity:Boolean = false;

            // Decode the Transport Stream Header
            _buffer.position = cursor;
            const headerRaw:uint = _buffer.readUnsignedInt();

            const raw_syncByte:uint         = (headerRaw & 0xff000000) >> 24;
            const raw_tei:Boolean           = (headerRaw & 0x00800000) != 0;
            const raw_pusi:Boolean          = (headerRaw & 0x00400000) != 0;
            const raw_tp:Boolean            = (headerRaw & 0x00200000) != 0;
            const raw_pid:uint              = (headerRaw & 0x001fff00) >> 8;
            const raw_scramble:uint         = (headerRaw & 0x000000c0) >> 6;
            const raw_hasAdaptation:Boolean = (headerRaw & 0x00000020) != 0;
            const raw_hasPayload:Boolean    = (headerRaw & 0x00000010) != 0;
            const raw_continuity:uint       = (headerRaw & 0x0000000f);

            if(logHeaders)
            {
                trace("TS Pkt @" + _totalConsumed + " sync=" + raw_syncByte + " pid=" + raw_pid + " tei=" + raw_tei + " pusi=" + raw_pusi + " tp=" + raw_tp + " scramble=" + raw_scramble + " adapt? " + raw_hasAdaptation + " continuity=" + raw_continuity);
            }

            // Handle adaptation field.
            if(raw_hasAdaptation)
            {
                var adaptationFieldLength:uint = _buffer.readUnsignedByte();
                if(adaptationFieldLength >= 183)
                {
                    trace("Saw only adaptation data, skipping TS packet.");
                    return;
                }

                headerLength += adaptationFieldLength + 1;
                
                discontinuity = (_buffer.readUnsignedByte() & 0x80) != 0;
            }
            
            payloadLength = 188 - headerLength;

            // Process payload.            
            if(!raw_hasPayload)
                return;

            if(raw_pid == 0x1fff)
            {
                trace("Skipping padding TS packet.");
                return;
            }

            // Allocate packet stream if none present.
            var stream:TSPacketStream = getPacketStream(raw_pid);

            if(stream.lastContinuity == raw_continuity)
            {
                // Ignore duplicate packets.
                if( (!raw_hasPayload)
                 && (!discontinuity))
                {
                    trace("WARNING: duplicate packet!");
                    return; // duplicate
                }
            }
            
            if(raw_pusi)
            {
                if(stream.buffer.length > 0 && stream.packetLength > 0)
                {
                    trace("WARNING: Flushed " + stream.buffer.length + " due to payloadStart flag, didn't predict length properly! (Guessed " + stream.packetLength + ")");
                }

                completeStreamPacket(stream);
            }
            else
            {
                if(stream.lastContinuity < 0)
                {
                    trace("WARNING: Saw discontinuous packet!");
                    return;
                }
                
                if( (((stream.lastContinuity + 1) & 0x0f) != raw_continuity) 
                    && !discontinuity)
                {
                    // Corrupt packet - skip it.
                    trace("WARNING: Saw corrupt packet, skipping!");
                    stream.buffer.length = 0;
                    stream.lastContinuity = -1;
                    return;
                }

                if(stream.buffer.length == 0 && length > 0)
                    trace("WARNING: Got new bytes without PUSI set!");
            }
            
            // Append to end.
            stream.buffer.position = stream.buffer.length;
            if(payloadLength > 0)
                stream.buffer.writeBytes(_buffer, cursor + headerLength, payloadLength);

            // Update continuity.
            stream.lastContinuity = raw_continuity;
            
            // Check to see if we can optimistically fire a complete PES packet...
            // We can also immediately process PMT packets.
            if((stream.packetLength > 0 && stream.buffer.length >= stream.packetLength + 6)
                || raw_pid == 0 || raw_pid == pesProcessor.pmtStreamId)
            {
                if(stream.buffer.length > stream.packetLength + 6)
                    trace("WARNING: Got buffer strictly longer (" + (stream.buffer.length - (stream.packetLength + 6)) + " bytes longer) than expected. This is OK when on first packet of stream.");
                completeStreamPacket(stream);
                stream.finishedLast = true;
            }


        }

        /**
         * We have a complete packet, append to the vector.
         */
        protected function completeStreamPacket(stream:TSPacketStream):void
        {
            if(stream.buffer.length == 0)
            {
                if(!stream.finishedLast)
                    trace("Tried to complete zero length packet.");
                stream.finishedLast = false;
                return;
            }

            // Append to buffer.
            trace("PES Packet " + stream.packetID + " length=" + stream.buffer.length + " raw=" + Hex.fromArray(stream.buffer, true, 32));
            pesProcessor.append(new PESPacket(stream.packetID, stream.buffer));

            // Reset stream buffer.
            stream.buffer.position = 0;
            stream.buffer.length = 0;
        }

        public function flush():void
        {
            trace("FLUSHING");
            for (var idx:* in _streams)
            {
                trace("Flushing stream id " + idx + " which has " + _streams[idx].buffer.length);
                completeStreamPacket(_streams[idx]);
            }

            pesProcessor.processAllNalus();
        }

        public function flushNalus():void
        {
            pesProcessor.processAllNalus();
        }

        public function clear(clearAACConfig:Boolean = true):void
        {
            _streams = {};
            pesProcessor.clear(clearAACConfig);
        }

        /**
         * Fire off a subtitle caption.
         */
        public function createAndSendCaptionMessage( timestamp:Number, captionBuffer:String, lang:String="", textid:Number=99):void
        {
            //pesProcessor.transcoder.createAndSendCaptionMessage( timestamp, captionBuffer, lang, textid);
        }

        /**
         * Allocate or retrieve the packet stream state for a given packet ID.
         */
        protected function getPacketStream(pid:int):TSPacketStream
        {
            var stream:TSPacketStream = _streams[pid];
            if(!stream)
            {
                stream = new TSPacketStream();
                stream.packetID = pid;
                _streams[pid] = stream;
            }
            return stream;
        }
    }

    /**
     * Assorted constants relating to the FLV format.
     */
    public class FLVTags
    {
        public static const HEADER_LENGTH:int = 11;
        public static const HEADER_VIDEO_FLAG:int = 0x01;
        public static const HEADER_AUDIO_FLAG:int = 0x04;
        public static const PREVIOUS_LENGTH_LENGTH:int = 4;
        
        public static const TYPE_AUDIO:int = 0x08;
        public static const TYPE_VIDEO:int = 0x09;
        public static const TYPE_SCRIPTDATA:int = 0x12;
        
        public static const AUDIO_CODEC_MP3:int = 0x2f;
        public static const AUDIO_CODEC_AAC:int = 0xaf;
        
        public static const VIDEO_CODEC_AVC_KEYFRAME:int = 0x17;
        public static const VIDEO_CODEC_AVC_PREDICTIVEFRAME:int = 0x27;
        
        public static const AVC_MODE_AVCC:int = 0x00;
        public static const AVC_MODE_PICTURE:int = 0x01;
        
        public static const AAC_MODE_CONFIG:int = 0x00;
        public static const AAC_MODE_FRAME:int = 0x01;
        
        public static const ADTS_FRAME_HEADER_LENGTH:uint = 7;
    }


    public class ExpGolomb 
    {
        private var _data : ByteArray;
        private var _bit : int;
        private var _curByte : uint;

        public function ExpGolomb(data : ByteArray) 
        {
            _data = data;
            data.position = 0;
            _bit = -1;
        }

        private function _readBit():uint 
        {
            var res : uint;
            if (_bit == -1) 
            {
                // read next
                _curByte = _data.readByte();
                _bit = 7;
            }
            res = (_curByte & (1 << _bit)) ? 1 : 0;
            _bit--;
            return res;
        }

        public function readBoolean():Boolean 
        {
            return (_readBit() == 1);
        }

        public function readBits(nbBits : uint):int 
        {
            var val : int = 0;
            for (var i : uint = 0; i < nbBits; ++i)
                val = (val << 1) + _readBit();
            return val;
        }

        public function readUE() : uint 
        {
            var nbZero : uint = 0;
            while (_readBit() == 0)
                ++nbZero;
            var x : uint = readBits(nbZero);
            return x + (1 << nbZero) - 1;
        }

        public function readSE() : uint 
        {
            var value : int = readUE();
            // the number is odd if the low order bit is set
            if (0x01 & value) {
                // add 1 to make it even, and divide by 2
                return (1 + value) >> 1;
            } else {
                // divide by two then make it negative
                return -1 * (value >> 1);
            }
        }
    }

    public class Hex {

        /**
         * Generates byte-array from given hexadecimal string
         *
         * Supports straight and colon-laced hex (that means 23:03:0e:f0, but *NOT* 23:3:e:f0)
         * The first nibble (hex digit) may be omitted.
         * Any whitespace characters are ignored.
         */
        public static function toArray(hex:String):ByteArray {
            hex = hex.replace(/^0x|\s|:/gm,'');
            var a:ByteArray = new ByteArray;
            if ((hex.length&1)==1) hex="0"+hex;
            for (var i:uint=0;i<hex.length;i+=2) {
                a[i/2] = parseInt(hex.substr(i,2),16);
            }
            return a;
        }

        /**
         * Generates lowercase hexadecimal string from given byte-array
         */
        public static function fromArray(array:ByteArray, colons:Boolean=false, count:int = Number.MAX_VALUE):String {
            var s:String = "";
            for (var i:uint=0;i<Math.min(array.length, count);i++) {
                s+=("0"+array[i].toString(16)).substr(-2,2);
                if (colons) {
                    if (i<array.length-1) s+=":";
                }
            }
            return s;
        }

        /**
         * Generates string from given hexadecimal string
         */
        public static function toString(hex:String, charSet:String='utf-8'):String {
            var a:ByteArray = toArray(hex);
            return a.readMultiByte(a.length, charSet);
        }

        /**
         * Convenience method for generating string using iso-8859-1
         */
        public static function toRawString(hex:String):String {
            return toString(hex, 'iso-8859-1');
        }

        /**
         * Generates hexadecimal string from given string
         */
        public static function fromString(str:String, colons:Boolean=false, charSet:String='utf-8'):String {
            var a:ByteArray = new ByteArray;
            a.writeMultiByte(str, charSet);
            return fromArray(a, colons);
        }

        /**
         * Convenience method for generating hexadecimal string using iso-8859-1
         */
        public static function fromRawString(str:String, colons:Boolean=false):String {
            return fromString(str, colons, 'iso-8859-1');
        }

    }

    /**
     * Constants for media class in an M2TS.
     */
    public class MediaClass
    {
        static public const OTHER:int = 0;
        static public const VIDEO:int = 1;
        static public const AUDIO:int = 2;
        
        static public function calculate(type:int):int
        {
            switch(type)
            {
                case 0x03: // ISO 11172-3 MP3 audio
                case 0x04: // ISO 13818-3 MP3-betterness audio
                case 0x0f: // AAC audio in ADTS transport syntax
                    return AUDIO;
                    
                case 0x1b: // H.264/MPEG-4 AVC
                    return VIDEO;
                    
                default:
                    return OTHER;
            }
        }
    }

    public class Util {
        
        public function Util() {
            throw new Error("Static class");
        }
        
        public static function strhex(str:String, size:int):Array {
            var i:int;
            var result:Array = new Array();
            for (i = 0; i < str.length; i += size) {
                result[i / size] = parseInt(str.substr(i, size), 16);
            }
            return result;
        }
        
        public static function hexstr(hex:Array, size:int):String {
            var i:int;
            var j:int;
            var result:String = new String();
            var tmp:String;
            for (i = 0; i < hex.length; i++) {
                tmp = hex[i].toString(16);
                if (tmp.length > size)
                    tmp = tmp.substr(tmp.length - size, size);
                else if (tmp.length < size) {
                    for (j = 0; j < size - tmp.length; j++)
                        tmp = '0' + tmp;
                }
                result += tmp;
            }
            return result;
        }
    
    }

    public class AESCrypter {
        
        public function AESCrypter() {
            throw new Error("Static class.");
        }
        
        private static var Nr:int = 14;
        /* Default to 256 Bit Encryption */
        private static var Nk:int = 8;
        
        /**
         * State of crypter, decryption or encryption.
         * @default flase
         */
        public static var Decrypt:Boolean = false;
        
        private static function enc_utf8(s:String):String {
            try {
                return unescape(encodeURIComponent(s));
            } catch (e:Error) {
                throw 'Error on UTF-8 encode';
            }
            return '';
        }
        
        private static function dec_utf8(s:String):String {
            try {
                return decodeURIComponent(escape(s));
            } catch (e:Error) {
                throw('Bad Key');
            }
            return '';
        }
        
        private static function padBlock(byteArr:Array):Array {
            var array:Array;
            var cpad:int;
            var i:int;
            if (byteArr.length < 16) {
                cpad = 16 - byteArr.length;
                array = new Array(cpad, cpad, cpad, cpad, cpad, cpad, cpad, cpad,
                                  cpad, cpad, cpad, cpad, cpad, cpad, cpad, cpad);
            } else
                array = new Array();
            for (i = 0; i < byteArr.length; i++) {
                array[i] = byteArr[i];
            }
            return array;
        }
        
        private static function block2s(block:Array, lastBlock:Boolean):void
        {
            var padding:int;
            var i:int;
            if (lastBlock) {
                padding = block[15];
                if (padding > 16) {
                    throw('Decryption error: Maybe bad key, saw padding of ' + padding);
                }
            }
        }
        
        /**
         * Converts byte array to string of hexademical numbers.
         * @param   numArr
         * @return string of hexademical numbers.
         */
        public static function a2h(numArr:Array):String {
            var string:String = new String();
            var i:int;
            for (i = 0; i < numArr.length; i++) {
                string += (numArr[i] < 16 ? '0' : '') + numArr[i].toString(16);
            }
            return string;
        }
        
        /**
         * Converts String of hexademical numbers to Array of int.
         * @param   s string of hexademical numbers representing byte array.
         * @return array of int.
         */
        public static function h2a(s:String):Array {
            var result:Array = new Array();
            s.replace(/(..)/g, function(... rest):String {
                    result.push(parseInt(rest[0], 16));
                    return rest[0];
                });
            return result;
        }
        
        /**
         * Convert String of text to Array of int.
         * @param   string text.
         * @param   binary if binary is true string will be procesed by endoceURIComponent.
         * @return array of int.
         */
        public static function s2a(string:String, binary:Boolean = false):Array {
            var array:Array = new Array();
            var i:int;
            
            if (!binary) {
                string = enc_utf8(string);
            }
            
            for (i = 0; i < string.length; i++) {
                array[i] = string.charCodeAt(i);
            }
            
            return array;
        }
        /**
         * Sets size of cypher key.
         * @param   newsize size of key to be set.
         */
        public static function size(newsize:int):void {
            switch (newsize) {
                case 128: 
                    Nr = 10;
                    Nk = 4;
                    break;
                case 192: 
                    Nr = 12;
                    Nk = 6;
                    break;
                case 256: 
                    Nr = 14;
                    Nk = 8;
                    break;
                default: 
                    throw('Invalid Key Size Specified:' + newsize);
            }
        }
        
        private static function randArr(num:int):Array {
            var result:Array = new Array();
            var i:int;
            for (i = 0; i < num; i++) {
                result.push(Math.floor(Math.random() * 256));
            }
            return result;
        }
        
        
        /**
         * Encrypt array of bytes.
         * @param   plaintext
         * @param   key
         * @param   iv
         * @return encrypted array.
         */
        public static function rawEncrypt(plaintext:Array, key:Array, iv:Array):Array {
            // plaintext, key and iv as byte arrays
            key = expandKey(key);
            var numBlocks:int = Math.ceil(plaintext.length / 16);
            var blocks:Array = new Array();
            var i:int;
            var cipherBlocks:Array = new Array();
            for (i = 0; i < numBlocks; i++) {
                blocks[i] = padBlock(plaintext.slice(i * 16, i * 16 + 16));
            }
            if (plaintext.length % 16 === 0) {
                blocks.push(new Array(16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16));
                // CBC OpenSSL padding scheme
                numBlocks++;
            }
            for (i = 0; i < blocks.length; i++) {
                blocks[i] = (i === 0) ? xorBlocks(blocks[i], iv) : xorBlocks(blocks[i], cipherBlocks[i - 1]);
                cipherBlocks[i] = encryptBlock(blocks[i], key);
            }
            return cipherBlocks;
        }
        
        /**
         * Decrypt array of bytes.
         * @param   cryptArr
         * @param   key
         * @param   iv
         * @param   binary
         * @return derrypted array.
         */
        public static function rawDecrypt(cryptArr:Array, key:Array, iv:Array, binary:Boolean = false):ByteArray {
            trace("     key           " + key.join(":"));

            // Don't forget to encrypt key.
            key = expandKey(key);

            // cryptArr, key and iv as byte arrays
            if(cryptArr.length % 16 != 0)
            {
                trace("Didn't get 16 block multiple");
                return null;
            }
            var numBlocks:int = cryptArr.length / 16;
            var cipherBlocks:Array = new Array();
            var plainBlocks:Array = new Array();

            var i:int;

            for (i = 0; i < numBlocks; i++) 
            {
                cipherBlocks.push(cryptArr.slice(i * 16, (i + 1) * 16));
            }

            for (i = 0; i < numBlocks; i++) 
            {
                plainBlocks[i] = decryptBlock(cipherBlocks[i], key);
                plainBlocks[i] = xorBlocks(plainBlocks[i], i==0 ? iv : cipherBlocks[i - 1]);
            }

            // Dump the first block
            trace("First cipher block " + cipherBlocks[0].join(":"));
            trace("First plain  block " + plainBlocks[0].join(":"));
            
            trace("Last cipher block " + cipherBlocks[numBlocks-1].join(":"));
            trace("Last  plain block " + plainBlocks[numBlocks-1].join(":"));

            // Check last block for padding.
            block2s(plainBlocks[plainBlocks.length-1], true); 

            var outBytes:ByteArray = new ByteArray();
            for(i=0; i<numBlocks; i++)
                for(var j:int=0; j<plainBlocks[i].length; j++)
                    outBytes.writeByte(plainBlocks[i][j]);

            return outBytes;
        }
        
        /**
         * Encripts block
         * @param   block block to be encrypted.
         * @param   words array of round keys.
         * @return encrypted block.
         */
        public static function encryptBlock(block:Array, words:Array):Array {
            Decrypt = false;
            var state:Array = addRoundKey(block, words, 0);
            var round:int;
            for (round = 1; round < (Nr + 1); round++) {
                state = subBytes(state);
                state = shiftRows(state);
                if (round < Nr) {
                    state = mixColumns(state);
                }
                //last round? don't mixColumns
                state = addRoundKey(state, words, round);
            }
            
            return state;
        }
        
        /**
         * Decrypts block.
         * @param   block block to be decrypted.
         * @param   words array of round keys.
         * @return decrypted block.
         */
        public static function decryptBlock(block:Array, words:Array):Array {
            Decrypt = true;
            var state:Array = addRoundKey(block, words, Nr);
            var round:int;
            for (round = Nr - 1; round > -1; round--) {
                state = shiftRows(state);
                state = subBytes(state);
                state = addRoundKey(state, words, round);
                if (round > 0) {
                    state = mixColumns(state);
                }
                    //last round? don't mixColumns
            }
            
            return state;
        }
        
        private static function subBytes(state:Array):Array {
            var S:Array = Decrypt ? SBoxInv : SBox;
            var temp:Array = new Array();
            var i:int;
            for (i = 0; i < 16; i++) {
                temp[i] = S[state[i]];
            }
            return temp;
        }
        
        private static function shiftRows(state:Array):Array {
            var temp:Array = new Array();
            var shiftBy:Array = Decrypt ? new Array(0, 13, 10, 7, 4, 1, 14, 11, 8, 5, 2, 15, 12, 9, 6, 3) : new Array(0, 5, 10, 15, 4, 9, 14, 3, 8, 13, 2, 7, 12, 1, 6, 11);
            var i:int;
            for (i = 0; i < 16; i++) {
                temp[i] = state[shiftBy[i]];
            }
            return temp;
        }
        
        private static function mixColumns(state:Array):Array {
            var t:Array = new Array();
            var c:int;
            if (!Decrypt) {
                for (c = 0; c < 4; c++) {
                    t[c * 4] = G2X[state[c * 4]] ^ G3X[state[1 + c * 4]] ^ state[2 + c * 4] ^ state[3 + c * 4];
                    t[1 + c * 4] = state[c * 4] ^ G2X[state[1 + c * 4]] ^ G3X[state[2 + c * 4]] ^ state[3 + c * 4];
                    t[2 + c * 4] = state[c * 4] ^ state[1 + c * 4] ^ G2X[state[2 + c * 4]] ^ G3X[state[3 + c * 4]];
                    t[3 + c * 4] = G3X[state[c * 4]] ^ state[1 + c * 4] ^ state[2 + c * 4] ^ G2X[state[3 + c * 4]];
                }
            } else {
                for (c = 0; c < 4; c++) {
                    t[c * 4] = GEX[state[c * 4]] ^ GBX[state[1 + c * 4]] ^ GDX[state[2 + c * 4]] ^ G9X[state[3 + c * 4]];
                    t[1 + c * 4] = G9X[state[c * 4]] ^ GEX[state[1 + c * 4]] ^ GBX[state[2 + c * 4]] ^ GDX[state[3 + c * 4]];
                    t[2 + c * 4] = GDX[state[c * 4]] ^ G9X[state[1 + c * 4]] ^ GEX[state[2 + c * 4]] ^ GBX[state[3 + c * 4]];
                    t[3 + c * 4] = GBX[state[c * 4]] ^ GDX[state[1 + c * 4]] ^ G9X[state[2 + c * 4]] ^ GEX[state[3 + c * 4]];
                }
            }
            
            return t;
        }
        
        private static function addRoundKey(state:Array, words:Array, round:int):Array {
            var temp:Array = new Array();
            var i:int;
            for (i = 0; i < 16; i++) {
                temp[i] = state[i] ^ words[round][i];
            }
            return temp;
        }
        
        private static function xorBlocks(block1:Array, block2:Array):Array {
            var temp:Array = new Array();
            var i:int;
            for (i = 0; i < 16; i++) {
                temp[i] = block1[i] ^ block2[i];
            }
            return temp;
        }
        
        /**
         * Performs key expansion.
         * @param   key cypher key.
         * @return array of round keys.
         */
        public static function expandKey(key:Array):Array {
            // Expects a 1d number array
            var w:Array = new Array();
            var temp:Array = new Array();
            var i:int;
            var r:Array;
            var t:int;
            var flat:Array = new Array();
            var j:int;
            
            for (i = 0; i < Nk; i++) {
                r = new Array(key[4 * i], key[4 * i + 1], key[4 * i + 2], key[4 * i + 3]);
                w[i] = r;
            }
            
            for (i = Nk; i < (4 * (Nr + 1)); i++) {
                w[i] = new Array;
                for (t = 0; t < 4; t++) {
                    temp[t] = w[i - 1][t];
                }
                if (i % Nk === 0) {
                    temp = subWord(rotWord(temp));
                    temp[0] ^= Rcon[i / Nk - 1];
                } else if (Nk > 6 && i % Nk === 4) {
                    temp = subWord(temp);
                }
                for (t = 0; t < 4; t++) {
                    w[i][t] = w[i - Nk][t] ^ temp[t];
                }
            }
            for (i = 0; i < (Nr + 1); i++) {
                flat[i] = new Array();
                for (j = 0; j < 4; j++) {
                    flat[i].push(w[i * 4 + j][0], w[i * 4 + j][1], w[i * 4 + j][2], w[i * 4 + j][3]);
                }
            }
            return flat;
        }
        
        private static function subWord(w:Array):Array { //side effect?
            // apply SBox to 4-byte word w
            var result:Array = new Array();
            var i:int;
            for (i = 0; i < 4; i++) {
                result[i] = SBox[w[i]];
            }
            return result;
        }
        
        private static function rotWord(w:Array):Array { //side effect?
            // rotate 4-byte word w left by one byte
            var tmp:int = w[0];
            var result:Array = new Array();
            var i:int;
            for (i = 0; i < 3; i++) {
                result[i] = w[i + 1];
            }
            result[3] = tmp;
            return result;
        }
        
        // jlcooke: 2012-07-12: added strhex + invertArr to compress G2X/G3X/G9X/GBX/GEX/SBox/SBoxInv/Rcon saving over 7KB, and added encString, decString
        
        private static function invertArr(arr:Array):Array {
            var i:int;
            var ret:Array = new Array();
            for (i = 0; i < arr.length; i++) {
                ret[arr[i]] = i;
            }
            return ret;
        }
        
        private static function Gxx(a:int, b:int):int {
            var i:int;
            var ret:int = 0;
            
            for (i = 0; i < 8; i++) {
                ret = ((b & 1) === 1) ? ret ^ a : ret;
                /* xmult */
                a = (a > 0x7f) ? 0x11b ^ (a << 1) : (a << 1);
                b >>>= 1;
            }
            
            return ret;
        }
        
        private static function Gx(x:int):Array {
            var i:int;
            var r:Array = new Array();
            for (i = 0; i < 256; i++) {
                r[i] = Gxx(x, i);
            }
            return r;
        }
        
        // S-box
        private static var SBox:Array = Util.strhex('637c777bf26b6fc53001672bfed7ab76ca82c97dfa5947f0add4a2af9ca472c0b7fd9326363ff7cc34a5e5f171d8311504c723c31896059a071280e2eb27b27509832c1a1b6e5aa0523bd6b329e32f8453d100ed20fcb15b6acbbe394a4c58cfd0efaafb434d338545f9027f503c9fa851a3408f929d38f5bcb6da2110fff3d2cd0c13ec5f974417c4a77e3d645d197360814fdc222a908846eeb814de5e0bdbe0323a0a4906245cc2d3ac629195e479e7c8376d8dd54ea96c56f4ea657aae08ba78252e1ca6b4c6e8dd741f4bbd8b8a703eb5664803f60e613557b986c11d9ee1f8981169d98e949b1e87e9ce5528df8ca1890dbfe6426841992d0fb054bb16', 2);
        
        // Precomputed lookup table for the inverse SBox
        private static var SBoxInv:Array = invertArr(SBox);
        
        // Rijndael Rcon
        private static var Rcon:Array = Util.strhex('01020408102040801b366cd8ab4d9a2f5ebc63c697356ad4b37dfaefc591', 2);
        
        private static var G2X:Array = Gx(2);
        
        private static var G3X:Array = Gx(3);
        
        private static var G9X:Array = Gx(9);
        
        private static var GBX:Array = Gx(0xb);
        
        private static var GDX:Array = Gx(0xd);
        
        private static var GEX:Array = Gx(0xe);
        
    }

}

import shell.FileSystem;
import flash.utils.*;

var totalBytes:int = 0;
var totalTime:int = 0;

function testFile(file:String, aesKey:String = null, iv:String = null)
{
    var t:int = getTimer();

    trace("====== OPENING " + file + " ============");
    var fileBytes:ByteArray = FileSystem.readByteArray(file);

    trace("   o length=" + fileBytes.length + " /16=" + (fileBytes.length/16));

    // Decrypt as appropriate. This is OpenSSL PKCS#7 compliant.
    if(aesKey != null)
    {
        var tmpArr:Array = [];
        fileBytes.position = 0;
        for(var i:int=0; i<fileBytes.length; i++)
            tmpArr[i] = fileBytes.readUnsignedByte();

        AESCrypter.size(128);

        var keyArr:Array = AESCrypter.h2a(aesKey);
        var ivArr:Array = AESCrypter.h2a(iv);
        trace(ivArr.join(":"));

        fileBytes = AESCrypter.rawDecrypt(tmpArr, keyArr, ivArr, true);

        fileBytes.position = 0;
    }

    var parser:TSPacketParser = new TSPacketParser();

    // Grab bytes in random chunks and feed to the parser.
    var totalCount:int = 0, totalChunks:int = 0;
    var tmp:ByteArray = new ByteArray();
    while(totalCount < fileBytes.length)
    {
        // Determine amount to transfer. Can't be zero, that has 
        // special semantics.
        tmp.position = 0;
        tmp.length = 0;
        var tmpCount:int = Math.random() * Math.random() * 4096 + 1;
        if(tmpCount > fileBytes.length - totalCount)
            tmpCount = fileBytes.length - totalCount;

        tmp.writeBytes(fileBytes, totalCount, tmpCount)

        //trace("Feeding " + tmp.length + " bytes! " + tmpCount)
        parser.appendBytes(tmp);

        // Update consumption stats.
        totalCount += tmpCount;
        totalChunks++;
    }

    trace("===== Flushing =====");
    parser.flush();

    totalBytes += parser.output.length;
    totalTime += (getTimer() - t);

    trace("Writing " + parser.output.length + " to " + file + ".flv, " + (totalBytes/totalTime).toFixed(1) + "bytes/ms");
    parser.output.position = 0;
    FileSystem.writeByteArray(file + ".flv", parser.output);
}

//testFile("seg-1-v1-a1.ts");
//testFile("aes_B000001.ts", "16cddae979afa745e8f3238e2cc5caa5", "00000000000000000000000000000001");
//testFile("aes_E00000002.ts", `"0a97c371cb796f7b8df519ca50648d08", "00000000000000000000000000000002");
//testFile("F00000002.ts", "172ed2454372d8c51ed0a236b81a615d", "00000000000000000000000000000002");
//testFile("aes_decrypt_B0000001.ts");
//testFile("seg-3-v1-a1.ts");
//testFile("seg-3-v1-a1.ts");
//testFile("seg-4-v1-a1.ts");
//testFile("20150326T035600-01-155106.ts");
testFile("media-uot1gpjgc_b882432_DVR_74.ts");

if(false)
for(var i:int=0; i<10; i++)
{
    testFile("a1.ts");    
    testFile("a0.ts");
    
    testFile("media-uagyzl1v4_b475136_DVR_1254.ts");
    testFile("media-uagyzl1v4_b475136_DVR_1256.ts");
    testFile("media-uagyzl1v4_b475136_DVR_1259.ts");
    testFile("media-uagyzl1v4_b475136_DVR_1255.ts");
    testFile("media-uagyzl1v4_b475136_DVR_1257.ts");
    testFile("seg-1-v1-a1.ts");
    testFile("seg-2-v1-a1.ts");
    testFile("seg-3-v1-a1.ts");
    testFile("seg-4-v1-a1.ts");
    testFile("seg-5-v1-a1.ts");
    testFile("seg-6-v1-a1.ts");
    testFile("test2.ts");
    testFile("test.ts");    
    testFile("b475136_1811.ts");
    testFile("b1017600_1825.ts");
}
