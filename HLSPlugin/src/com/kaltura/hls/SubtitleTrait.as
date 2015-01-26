package com.kaltura.hls
{
	import com.kaltura.hls.manifest.HLSManifestPlaylist;
	import com.kaltura.hls.subtitles.SubTitleParser;
	
	import org.osmf.traits.MediaTraitBase;
	
	public class SubtitleTrait extends MediaTraitBase
	{
		public static const TYPE:String = "subtitle";
		
		private var _playLists:Vector.<HLSManifestPlaylist> = new <HLSManifestPlaylist>[];
		private var _languages:Vector.<String> = new <String>[];
		private var _language:String = "eng";
		
		public function SubtitleTrait()
		{
			super(TYPE);
		}
		
		public function set playLists( value:Vector.<HLSManifestPlaylist> ):void
		{
			_playLists.length = 0;
			_languages.length = 0;
			
			if ( !value ) return;
			
			for ( var i:int = 0; i < value.length; i++ )
			{
				_playLists.push( value[ i ] );
				_languages.push( value[ i ].name );
			}
		}
		
		public function set language( value:String ):void
		{
			_language = value;
		}
		
		public function get language():String
		{
			return _language;
		}
		
		public function get languages():Vector.<String>
		{
			return _languages;
		}
		
		public function get activeSubtitles():Vector.<SubTitleParser>
		{
			if ( _language == "" ) return null;
			for ( var i:int = 0; i < _playLists.length; i++ )
			{
				// If the playlist has a language associated with it, use that language
				var language:String;
				if (_playLists[ i ].language && _playLists[ i ].language != "")
					language = _playLists[ i ].language;
				else
					language = _playLists[ i ].name;
				
				if (language == _language ) return _playLists[ i ].manifest.subtitles;
			}
			return null;
		}
	}
}