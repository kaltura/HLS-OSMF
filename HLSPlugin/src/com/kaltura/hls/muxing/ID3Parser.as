package com.kaltura.hls.muxing
{
	import flash.utils.ByteArray;
	
	/**
	 * Very simple ID3 parser that can extract timestamp data for an HLS AAC 
	 * stream.
	 * 
	 * Refer to the ID3 spec for details: http://id3.org/id3v2.4.0-structure 
	 */
	public class ID3Parser
	{
		public var lengthInBytes:int;
		public var hasTimestamp:Boolean = false;
		public var timestamp:Number;
		
		public function parse(data:ByteArray):void
		{
			var tagSize:uint = 0;
			try
			{
				var pos:Number = data.position;
				var header:String;
				
				do
				{
					header = data.readUTFBytes(3);
					switch(header)
					{
						case "ID3":
						trace("Got ID3 at " + data.position);

							data.position += 3;
							
							// retrieve tag length
							var byte1:uint = data.readUnsignedByte() & 0x7f;
							var byte2:uint = data.readUnsignedByte() & 0x7f;
							var byte3:uint = data.readUnsignedByte() & 0x7f;
							var byte4:uint = data.readUnsignedByte() & 0x7f;
							tagSize = (byte1 << 21) + (byte2 << 14) + (byte3 << 7) + byte4;
							
							var endingPosition:Number = data.position + tagSize;
							
							// Look for the PRIV entry.
							if (data.readUTFBytes(4) == "PRIV")
							{
								while(data.position + 53 <= endingPosition) 
								{
									// owner should be "com.apple.streaming.transportStreamTimestamp"
									if(data.readUTFBytes(44) != 'com.apple.streaming.transportStreamTimestamp')
									{
										// Rewind and keep looking.
										data.position -= 43;
										continue;
									}
									
									data.position += 4;
									
									var cursor:int = data.position;
									var pts:Number = 0;

					                pts  = data[cursor] & 0x01; pts = pts << 8;
					                pts  += data[cursor + 1];    pts = pts << 8;
					                pts  += data[cursor + 2];    pts = pts << 8;
					                pts  += data[cursor + 3];    pts = pts << 8;
					                pts  += data[cursor + 4];

									timestamp = pts / 90;
									trace("saw timestamp " + timestamp + " pts=" + pts + "@ " + cursor);
									hasTimestamp = true;
									return;
								}								
							}

							data.position = endingPosition;
							break;
						
						case "3DI":
							data.position += 7;
							break;
						
						default:
							data.position -= 3;
							lengthInBytes = data.position - pos;
							return;
							
							break;
					}
				} while (true);
			}
			catch(e:Error)
			{
				// TODO: Handle failure?
			}
			
			// Clean up state.
			lengthInBytes = 0;
		}
	}
}
