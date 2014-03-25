package com.kaltura.hls.subtitles
{
	public class TextTrackCue
	{
		private static const STATE_WHITESPACE:String = "WhiteSpace";
		private static const STATE_TIMESTAMP:String = "TimeStamp";
		private static const STATE_PARSE_TOKENS:String = "ParseTokens";
		
		public var id:String = "";
		public var pauseOnExit:Boolean = false;
		public var regionName:String = "";
		public var region:WebVTTRegion = null;
		public var writingDirection:String = "horizontal";
		public var snapToLines:Boolean = false;
		public var linePosition:String = "auto";
		public var lineAlignment:String = "start alignment";
		public var textPosition:int = 50;
		public var textPositionAlignment:String = "middle alignment";
		public var size:int = 100;
		public var textAlignment:String = "middle alignment";
		public var text:String = "";
		public var buffer:String = "";
		
		public var startTime:Number = -1;
		public var endTime:Number = -1;
		
		public function TextTrackCue()
		{
		}
		
		public function parse( input:String ):void
		{
			var position:int = 0;
			var state:String = STATE_WHITESPACE;
			var accum:String = "";
			
			// Remove tabs, just in case
			input = input.split( "\t" ).join( " " );
			
			while ( position < input.length )
			{
				var char:String = input.charAt( position );
				
				switch ( state )
				{
					case STATE_WHITESPACE:
						if ( char == " " ) position++;
						else if ( startTime == -1 || endTime == -1 ) state = STATE_TIMESTAMP;
						else state = STATE_PARSE_TOKENS;
						break;
					
					case STATE_TIMESTAMP:
						if ( char == " " || position == input.length - 1 )
						{
							var timeStamp:Number = SubTitleParser.parseTimeStamp( accum );
							if ( startTime == -1 ) startTime = timeStamp;
							else endTime = timeStamp;
							accum = "";
							var arrowIndex:int = input.indexOf( "-->", position );
							if ( arrowIndex != -1 ) position = arrowIndex + 3; 
							state = STATE_WHITESPACE;
							break;
						}
						accum += char;
						position++;
						break;
						
					case STATE_PARSE_TOKENS:
						parseTokens( input.substring( position ) );
						position = input.length;
						break;
				}
			}
		}
		
		private function parseTokens( input:String ):void
		{
			var tokens:Array = input.split( " " );
			for ( var i:int = 0; i < tokens.length; i++ )
			{
				var token:String = tokens[ i ];
				var colonIndex:int = token.indexOf( ":" );
				
				if ( colonIndex == -1 ) continue;
				
				var name:String = token.substring( 0, colonIndex );
				var value:String = token.substring( colonIndex + 1 );
				var positionSet:Boolean = false;
				var positionAlignSet:Boolean = false;
				
				switch ( name )
				{
					case "region":
						regionName = value;
						break;
					
					case "vertical":
						writingDirection = value;
						break;
					
					case "line":
						// Not yet implemented
						break;
					
					case "size":
						// Not yet implemented
						break;
					
					default:
						trace( "Unknown tag " + name + ". Ignoring." );
				}
			}
		}
		
	}
}