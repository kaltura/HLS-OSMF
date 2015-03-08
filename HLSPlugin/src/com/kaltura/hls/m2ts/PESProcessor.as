package com.kaltura.hls.m2ts
{
    import flash.utils.ByteArray;
    import flash.net.ObjectEncoding;
    import flash.utils.ByteArray;
    import flash.utils.Endian;    
    import flash.utils.IDataInput;
    import flash.utils.IDataOutput;
    import com.hurlant.util.Hex;

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

        public function logStreams():void
        {
            trace("----- PES state -----");
            for(var k:* in streams)
            {
                trace("   " + k + " has " + streams[k].buffer.length + " bytes, type=" + types[k]);
            }
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
                    hasVideo = true

                if(mediaClass == MediaClass.AUDIO)
                    hasAudio = true

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
            transcoder.writeHeader(hasAudio, hasVideo);
            headerSent = true;
            
            return true;
        }

        public function append(packet:PESPacket):void
        {
            var b:ByteArray = packet.buffer;
            b.position = 0;

            // Get the start code.
            var startCode:uint = b.readUnsignedInt();
            if((startCode & 0xFFFFFF00) != 0x00000100)
            {
                // It could be a program association table.
                if((startCode & 0xFFFFFF00) == 0x0000b000)
                {
                    trace("Ignoring program association table.");
                    return;
                }

                // It could be the program map table.
                if((startCode & 0xFFFFFC00) == 0x0002b000)
                {
                    parseProgramMapTable(b, 1);
                    return;
                }

                var tmp:ByteArray = new ByteArray();
                tmp.writeInt(startCode);
                trace("ES prefix was wrong, expected 00:00:01:xx but got " + Hex.fromArray(tmp, true));
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
                    trace("WARNING: parsePESPacket - invalid decode timestamp");
                    return;
                }
                
                pes = new PESPacketStream();
                streams[packet.packetID] = pes;
            }
            else
            {
                pes = streams[packet.packetID];
            }
            
            if(headerSent == false)
            {
                trace("Skipping data that came before PMT");
                return;
            }

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

                // Convert previous data.
                if(lastVideoNALU)
                    transcoder.convert(lastVideoNALU);

                // Generate a new NALU. (Sanity.)
                if(!lastVideoNALU)
                    lastVideoNALU = new NALU();
                if(!lastVideoNALU.buffer)
                    lastVideoNALU.buffer = new ByteArray();

                // Update NALU state.
                lastVideoNALU.pts = pts;
                lastVideoNALU.dts = dts;
                lastVideoNALU.buffer.position = 0;
                lastVideoNALU.buffer.length = b.length - cursor;
                lastVideoNALU.buffer.writeBytes(b, cursor);

            }
            else if(types[packet.packetID] == 0x0F)
            {
                // It's an AAC stream.
                transcoder.convertAAC(packet);
            }
            else if(types[packet.packetID] == 0x03 || types[packet.packetID] == 0x04)
            {
                // It's an MP3 stream. Pass through directly.
                transcoder.convertMP3(packet);
            }
            else
            {
                trace("Unknown packet ID type " + types[packet.packetID] + ", ignoring.");
            }
        }

    }
}