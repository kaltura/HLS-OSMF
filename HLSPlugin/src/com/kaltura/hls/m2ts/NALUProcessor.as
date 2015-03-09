package com.kaltura.hls.m2ts
{
    import flash.utils.ByteArray;
    import flash.net.ObjectEncoding;
    import flash.utils.ByteArray;
    import flash.utils.Endian;    
    import flash.utils.IDataInput;
    import flash.utils.IDataOutput;

    /**
     * NALU processing utilities.
     */
    public class NALUProcessor
    {
        private static var ppsList:Vector.<ByteArray>;
        private static var spsList:Vector.<ByteArray>;
        
        private static function sortSPS(a:ByteArray, b:ByteArray):int
        {
            var ourEg:ExpGolomb = new ExpGolomb(a);
            ourEg.readBits(28);
            var Id_a:int = ourEg.readUE();

            ourEg = new ExpGolomb(b);
            ourEg.readBits(28);
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
        private static function serializeAVCC():ByteArray
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

                //trace("SPS #" + i + " profile " + spsList[i][1] + "   " + Hex.fromArray(spsList[i], true));

                var eg:ExpGolomb = new ExpGolomb(spsList[i]);
                // constraint_set[0-5]_flag, u(1), reserved_zero_2bits u(2), level_idc u(8)
                eg.readBits(16);
                //trace("Saw id " + eg.readUE());

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
                //trace("PPS length #" + i + " is " + ppsLength + "   " + Hex.fromArray(ppsList[i], true));
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
            ourEg.readBits(16);
            var ourId:int = ourEg.readUE();

            // If not present in list add it!
            var found:Boolean = false;
            for(var i:int=0; i<spsList.length; i++)
            {
                // If it matches our ID, replace it.
                var eg:ExpGolomb = new ExpGolomb(spsList[i]);
                eg.readBits(16);
                var foundId:int = eg.readUE();

                if(foundId == ourId)
                {
                    //trace("Got SPS match for " + foundId + "!");
                    spsList[i] = sps;
                    return;
                }

                if(spsList[i].length != length)
                    continue;

                // If identical don't append to list.
                for(var j:int=0; j<spsList[i].length && j<sps.length; j++)
                    if(spsList[i][j] != sps[j])
                        continue;

                found = true;
                break;
            }

            // Maybe we do have to add it!
            if(!found)
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
            var ourId:int = ourEg.readUE();

            // If not present in list add it!
            var found:Boolean = false;
            for(var i:int=0; i<ppsList.length; i++)
            {
                // If it matches our ID, replace it.
                var eg:ExpGolomb = new ExpGolomb(ppsList[i]);
                var foundId:int = eg.readUE();

                if(foundId == ourId)
                {
                    //trace("Got PPS match for " + foundId + "!");
                    ppsList[i] = pps;
                    return;
                }

                if(ppsList[i].length != length)
                    continue;

                // If identical don't append to list.
                for(var j:int=0; j<ppsList[i].length && j<pps.length; j++)
                    if(ppsList[i][j] != pps[j])
                        continue;

                found = true;
                break;
            }

            // Maybe we do have to add it!
            if(!found)          
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
                
                callback(bytes, uint(start), naluLength);
                
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

            return tmp;
        }

        private static function extractAVCCInner(bytes:ByteArray, cursor:uint, length:uint):void
        {
            // What's the type?
            var naluType:uint = bytes[cursor] & 0x1f;

            if(naluType == 7)
            {
                // Handle SPS
                var spsStripped:ByteArray = stripEmulationBytes(bytes, cursor, length);
                setAVCSPS(spsStripped, 0, spsStripped.length)
            }
            else if(naluType == 8)
            {
                // Handle PPS
                var ppsStripped:ByteArray = stripEmulationBytes(bytes, cursor, length);
                setAVCPPS(ppsStripped, 0, ppsStripped.length)
            }
            else
            {
                // Ignore.
            }
        }

        /**
         * Scan a set of NALUs and come up with an AVCC record.
         */
        public static function extractAVCC(unit:NALU):ByteArray
        {
            // Clear the buffers.
            spsList = new Vector.<ByteArray>();
            ppsList = new Vector.<ByteArray>();

            // Go through each buffer and find all the SPS/PPS info.
            walkNALUs(unit.buffer, 0, extractAVCCInner)

            // Generate and return the AVCC.
            return serializeAVCC();
        }
    }
}