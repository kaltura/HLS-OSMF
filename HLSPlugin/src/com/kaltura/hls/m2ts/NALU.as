package com.kaltura.hls.m2ts
{
    import flash.utils.ByteArray;
    import flash.net.ObjectEncoding;
    import flash.utils.ByteArray;
    import flash.utils.Endian;    
    import flash.utils.IDataInput;
    import flash.utils.IDataOutput;

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

}