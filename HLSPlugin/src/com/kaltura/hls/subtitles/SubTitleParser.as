package com.kaltura.hls.subtitles
{
	import flash.events.Event;
	import flash.events.EventDispatcher;
	import flash.events.IOErrorEvent;
	import flash.events.SecurityErrorEvent;
	import flash.net.URLLoader;
	import flash.net.URLRequest;
	
	public class SubTitleParser extends EventDispatcher
	{
		public var regions:Vector.<WebVTTRegion> = new <WebVTTRegion>[];
		
		private static const STATE_IDLE:String = "Idle";
		private static const STATE_PARSE_HEADERS:String = "ParseHeaders";
		private static const STATE_PARSE_CUE_SETTINGS:String = "ParseCueSettings";
		private static const STATE_PARSE_CUE_TEXT:String = "ParseCueText";
		
		private static const STATE_COLLECT_MINUTES:String = "CollectMinutes";
		private static const STATE_COLLECT_HOURS:String = "CollectHours";
		private static const STATE_COLLECT_SECONDS:String = "CollectSeconds";
		private static const STATE_COLLECT_MILLISECONDS:String = "CollectMilliseconds";

		public var textTrackCues:Vector.<TextTrackCue> = new <TextTrackCue>[];
		public var startTime:Number = -1;
		public var endTime:Number = -1;
		
		private var _loader:URLLoader;
		private var _url:String;
		
		public function SubTitleParser( url:String = "" )
		{
			super();
			if ( url ) load( url );
		}
		
		public function getCuesForTimeRange( startTime:Number, endTime:Number ):Vector.<TextTrackCue>
		{
			var result:Vector.<TextTrackCue> = new <TextTrackCue>[];
			for ( var i:int = 0; i < textTrackCues.length; i++ )
			{
				var cue:TextTrackCue = textTrackCues[ i ];
				if ( cue.startTime > endTime ) break;
				if ( cue.startTime >= startTime ) result.push( cue );
			}
			return result;
		}
		
		public function load( url:String ):void
		{
			_url = url;
			_loader = new URLLoader( new URLRequest( url ) );
			_loader.addEventListener(Event.COMPLETE, onLoaded );
			_loader.addEventListener(IOErrorEvent.IO_ERROR, onLoadError);
			_loader.addEventListener(SecurityErrorEvent.SECURITY_ERROR, onLoadError);
		}
		
		public function parse( input:String ):void
		{
			// Normalize line endings.
			input = input.replace("\r\n", "\n");
			
			// split into array.
			var lines:Array = input.split("\n");
			
			if ( lines.length < 1 || lines[ 0 ].indexOf( "WEBVTT" ) == -1 )
			{
				trace( "Not a valid WEBVTT file " + _url );
				dispatchEvent( new Event( Event.COMPLETE ) );
				return;
			}
			
			var state:String = STATE_PARSE_HEADERS;
			var textTrackCue:TextTrackCue;
			
			// Process each line.
			
			for ( var i:int = 1; i < lines.length; i++ )
			{
				var line:String = lines[ i ];
				if ( line == "" )
				{
					// If new line, we're done with last parsing step. Make sure we skip all new lines.
					state = STATE_IDLE;
					if ( textTrackCue ) textTrackCues.push( textTrackCue );
					textTrackCue = null;
					continue;
				}

				switch ( state )
				{
					case STATE_PARSE_HEADERS:
						// Only support region headers for now
						if ( line.indexOf( "Region:" ) == 0 ) regions.push( WebVTTRegion.fromString( line ) );
						break;
					
					case STATE_IDLE:
						// New text track cue
						textTrackCue = new TextTrackCue();
						
						// If this line is the cue's ID, set it and break. Otherwise proceed to settings with current line. 
						if ( line.indexOf( "-->" ) == -1 )
						{
							textTrackCue.id = line;
							textTrackCue.buffer += line + "\n";
							break;
						}
						
					case STATE_PARSE_CUE_SETTINGS:
						textTrackCue.parse( line );
						textTrackCue.buffer += line;
						state = STATE_PARSE_CUE_TEXT;
						break;
					
					case STATE_PARSE_CUE_TEXT:
						if ( textTrackCue.text != "" ) textTrackCue.text += "\n";
						textTrackCue.text += line;
						textTrackCue.buffer += "\n" + line;
						break;
				}
			}
			
			var firstElement:TextTrackCue = textTrackCues.length > 0 ? textTrackCues[ 0 ] : null;
			var lastElement:TextTrackCue = textTrackCues.length > 1 ? textTrackCues[ textTrackCues.length - 1 ] : firstElement;
			
			// Set start and end times for this file
			if ( firstElement != null )
			{
				startTime = firstElement.startTime;
				endTime = lastElement.endTime;
			}
			
			dispatchEvent( new Event( Event.COMPLETE ) );
		}
		
		
		
		public static function parseTimeStamp( input:String ):Number
		{
			// Time string parsed from format 00:00:00.000 and similar
			var hours:int = 0;
			var minutes:int = 0;
			var seconds:int = 0;
			var milliseconds:int = 0;
			var units:Array = input.split( ":" );
			var secondUnits:Array;
			
			if ( units.length < 3 )
			{
				minutes = int( units[ 0 ] );
				secondUnits = units[ 1 ].split( "." );
			}
			else
			{
				hours = int( units[ 0 ] );
				minutes = int( units[ 1 ] );
				secondUnits = units[ 2 ].split( "." );
			}
			
			seconds = int( secondUnits[ 0 ] );
			if ( secondUnits.length > 1 ) milliseconds = int( secondUnits[ 1 ] );

			return hours * 60 * 60 + minutes * 60 + seconds + milliseconds / 1000;
		}
		
		private function onLoaded( e:Event ):void
		{
			parse( _loader.data );
		}
		
		private function onLoadError( e:Event ):void
		{
			trace( "CAN'T LOAD FILE" );
			dispatchEvent( new Event( Event.COMPLETE ) );
		}
	}
}