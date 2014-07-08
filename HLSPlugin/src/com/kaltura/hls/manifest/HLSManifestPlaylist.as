package com.kaltura.hls.manifest
{
	import flash.utils.Dictionary;

	public class HLSManifestPlaylist extends BaseHLSManifestItem
	{
		public var groupId:String = "";
		public var language:String = "";
		public var name:String = "";
		public var autoSelect:Boolean;
		public var isDefault:Boolean;
		
		private static const PROPERTY_MAP:Dictionary = new Dictionary();
		{
			PROPERTY_MAP[ "TYPE" ]			= "type";
			PROPERTY_MAP[ "GROUP-ID" ]		= "groupId";
			PROPERTY_MAP[ "LANGUAGE" ]		= "language";
			PROPERTY_MAP[ "NAME" ]			= "name";
			PROPERTY_MAP[ "AUTOSELECT" ]	= "autoSelect";
			PROPERTY_MAP[ "DEFAULT" ]		= "isDefault";
			PROPERTY_MAP[ "URI" ]			= "uri";
		}
		
		public static function fromString(input:String):HLSManifestPlaylist
		{
			// Input like this:
			// TYPE=AUDIO,GROUP-ID="myGroup",LANGUAGE="eng",NAME="myAudio",AUTOSELECT=NO,DEFAULT=NO,URI="path/to/asset.m3u8"
			
			var result:HLSManifestPlaylist = new HLSManifestPlaylist();
			result.parseKeyPairs( input );
			return result;
		}
		
		private function parseKeyPairs( input:String ):void
		{
			var firstCommaIndex:int = input.indexOf(',');
			var firstEqualSignIndex:int = input.indexOf('=');
			var firstQuoteIndex:int = input.indexOf('"');
			var endIndex:int = firstCommaIndex > -1 ? firstCommaIndex : input.length + 1;
			
			var key:String = input.substring( 0, firstEqualSignIndex );
			
			// We need to check and see if there are any spaces or tabs after the comma
			while(key.charAt(0) == " " || key.charAt(0) == "\t")
			{
				// If we find an invalid character, move the string up one index
				key = key.substring(1);
			}
			
			var value:String;
			
			if ( firstEqualSignIndex == -1 )
			{
				trace( "ENCOUNTERED BAD KEY PAIR IN '" + input + "', IGNORING." );
				return;
			}
			else if ( firstQuoteIndex == -1 || ( firstCommaIndex > -1 && firstQuoteIndex > firstCommaIndex ) )
			{
				value = input.substring( firstEqualSignIndex + 1, endIndex );
			}
			else
			{
				var secondQuoteIndex:int = input.indexOf( '"', firstQuoteIndex + 1 );
				var endCommaIndex:int = input.indexOf( ',', secondQuoteIndex );
				value = input.substring( firstQuoteIndex + 1, secondQuoteIndex );
				endIndex = endCommaIndex > -1 ? endCommaIndex : input.length;
			}
			
			var propertyName:String = PROPERTY_MAP[ key ];
			setProperty( propertyName, value );
			
			var newInput:String = input.substring( endIndex + 1 );
			if ( newInput.length > 0 ) parseKeyPairs( newInput );
		}
		
		private function setProperty( propertyName:String, value:String ):void
		{
			if ( !propertyName || !this.hasOwnProperty( propertyName ) ) return;
			if ( this[ propertyName ] is Boolean ) this[ propertyName ] = value == "YES";
			else this[ propertyName ] = value; 
		}
	}
}
