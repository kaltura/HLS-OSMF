package com.kaltura.hls.manifest
{
	public class HLSManifestStream extends BaseHLSManifestItem
	{
		public var programId:int;
		public var bandwidth:int;
		public var codecs:String;
		public var width:int, height:int;
		public var backupStream:HLSManifestStream;
		public var numBackups:int = 0;
		
		public static function fromString(input:String):HLSManifestStream
		{
			// Input like this:
			// PROGRAM-ID=1,BANDWIDTH=319060,CODECS="mp4a.40.2,avc1.66.30",RESOLUTION=304x128
			
			var newNote:HLSManifestStream = new HLSManifestStream();
			
			newNote.type = HLSManifestParser.VIDEO;
			
			var accum:String = "";
			var tmpKey:String = null;
			for(var i:int=0; i<input.length; i++)
			{
				var curChar:String = input.charAt(i);
				
				if(curChar == "=")
				{
					if(tmpKey != null)
						trace("Found unexpected =");
					
					tmpKey = accum;
					accum = "";
					continue;
				}
				
				if(curChar == "," || i == input.length - 1)
				{
					// Grab the last character and accumulate it.
					if(i == input.length - 1)
						accum += curChar;
					
					if(tmpKey == null)
					{
						trace("No key set but found end of key-value pair, ignoring...");
						continue;
					}
					
					// We found the end of a value.
					switch(tmpKey)
					{
						case "PROGRAM-ID":
							newNote.programId = parseInt(accum);
							break;
						case "BANDWIDTH":
							// We devide this value by 1000 to convert into Kilobits
							newNote.bandwidth = parseInt(accum) / 1000;
							break;
						case "CODECS":
							newNote.codecs = accum;
							break;
						case "RESOLUTION":
							var resSplit:Array = accum.split("x");
							newNote.width = parseInt(resSplit[0]);
							newNote.height = parseInt(resSplit[1]);
							break;
						default:
							trace("Unexpected key '" + tmpKey + "', ignoring...");
							break;
					}
					
					tmpKey = null;
					accum = "";
					continue;
				}
			
				if(curChar == "\"")
				{
					// Walk ahead until next ", this is a quoted string.
					curChar = "";
					for(var j:int=i+1; j<input.length; j++)
					{
						if(input.charAt(j) == "\"")
							break;
						curChar += input.charAt(j);
					}
					
					// Bump our next character.
					i = j;
				}
				
				// Build up the accumulator.
				accum += curChar;
			}
			
			return newNote;
		}
	}
}