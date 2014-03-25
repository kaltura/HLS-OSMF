package com.kaltura.hls.subtitles
{
	public class WebVTTRegion
	{
		public static const SCROLL_UP:String = "scroll up";
		public static const SCROLL_NONE:String = "scroll none";
		
		// Default values set from the WebVTT specification
		public var id:String = "";
		public var width:Number = 100;
		public var lines:int = 3;
		public var anchorX:Number = 0;
		public var anchorY:Number = 100;
		public var viewportAnchorX:Number = 0;
		public var viewportAnchorY:Number = 100;
		public var scroll:String = SCROLL_NONE;
		
		public function WebVTTRegion()
		{
		}
		
		public static function fromString( input:String ):WebVTTRegion
		{
			var result:WebVTTRegion = new WebVTTRegion();
			
			var settings:Array = input.split( " " );
			
			for ( var i:int = 0; i < settings.length; i++ )
			{
				var token:String = settings[ i ];
				var equalsIndex:int = token.indexOf( "=" );
				
				// Check if valid token, otherwise skip
				if ( equalsIndex < 1 || equalsIndex == token.length - 1 ) continue; 
				
				var name:String = token.substring( 0, equalsIndex );
				var value:String = token.substring( equalsIndex + 1 );
				
				switch ( name )
				{
					case "id":
						result.id = value;
						break;
					
					case "width":
						result.width = parsePercentage( value );
						break;
					
					case "lines":
						result.lines = int( value );
						break;
					
					case "regionanchor":
						var commaIndex:int = value.indexOf( "," );
						result.anchorX = parsePercentage( value.substring( 0, commaIndex ) );
						result.anchorY = parsePercentage( value.substring( commaIndex + 1 ) );
						break;
					
					case "viewportanchor":
						var comma2Index:int = value.indexOf( "," );
						result.viewportAnchorX = parsePercentage( value.substring( 0, comma2Index ) );
						result.viewportAnchorY = parsePercentage( value.substring( comma2Index + 1 ) );
						break;
					
					case "scroll":
						if ( value == "up" ) result.scroll = SCROLL_UP;
						break;
					
					default:
						trace( "Unknown token " + name + ", ignoring." );
						break;
				}
			}
			
			return result;
		}
		
		private static function parsePercentage( input:String ):Number
		{
			if ( input.charAt( input.length - 1 ) != "%" ) return 0;
			else return Number( input.substring( 0, input.length - 1 ) );
		}
	}
}