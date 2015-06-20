package com.kaltura.hls
{
	import com.kaltura.hls.manifest.HLSManifestPlaylist;
	import com.kaltura.hls.manifest.HLSManifestParser;
	import com.kaltura.hls.subtitles.SubTitleParser;
	import com.kaltura.hls.subtitles.TextTrackCue;
	import com.kaltura.hls.HLSDVRTimeTrait;

	import org.osmf.traits.MediaTraitBase;
	import org.osmf.traits.MediaTraitType;
	import org.osmf.traits.TimeTrait;
	import org.osmf.traits.SeekTrait;

	import org.osmf.media.MediaElement;

	import flash.events.*;
	import flash.utils.*;
	
	public class SubtitleTrait extends MediaTraitBase
	{
		public static const TYPE:String = "subtitle";
		
		private var _playLists:Vector.<HLSManifestPlaylist> = new <HLSManifestPlaylist>[];
		private var _languages:Vector.<String> = new <String>[];
		private var _language:String = "";

		public var owningMediaElement:MediaElement;

		private var _lastCue:TextTrackCue;
		private var _lastInjectedSubtitleTime:Number = -1;

		private static var activeTrait:SubtitleTrait = null;
		private static var activeReload:HLSManifestParser;
		private static var reloadLanguage:String = null;
		private static var _reloadTimer:Timer;
		private static var _subtitleTimer:Timer;
		
		public function SubtitleTrait()
		{
			super(TYPE);

			activeTrait = this;

			if(!_reloadTimer)
			{
				trace("SubTitleTrait - starting reload timer");
				_reloadTimer = new Timer(1000);
				_reloadTimer.addEventListener(TimerEvent.TIMER, onReloadTimer);
				_reloadTimer.start();
			}

			if(!_subtitleTimer)
			{
				trace("SubTitleTrait - starting subtitle timer");
				_subtitleTimer = new Timer(50);
				_subtitleTimer.addEventListener(TimerEvent.TIMER, onSubtitleTimer);
				_subtitleTimer.start();
			}

		}

		/**
		 * Fired frequently to emit any new subtitle events based on playhead position.
		 */
		private static function onSubtitleTimer(e:Event):void
		{
			// If no trait/no titles, ignore it.
			if(activeTrait == null || activeTrait.activeSubtitles == null)
				return;

			// Otherwise, attempt to get the time trait and determine our current playtime.
			if(!activeTrait.owningMediaElement)
				return;

			var tt:TimeTrait = activeTrait.owningMediaElement.getTrait(MediaTraitType.TIME) as TimeTrait;
			if(!tt)
				return;

			// Great, time is knowable - so what is it?
			var curTime:Number = tt.currentTime;
			if(tt is HLSDVRTimeTrait)
				curTime = (tt as HLSDVRTimeTrait).absoluteTime;
			
			// This is quite verbose but useful for debugging.
			// trace("onSubtitleTimer - Current time is: " + curTime);

			// Now, fire off any subtitles that are new.
			activeTrait.emitSubtitles(activeTrait._lastInjectedSubtitleTime, curTime);
		}

		/**
		 * Actually fire subtitle events for any subtitles in the specified period.
		 */
		private function emitSubtitles( startTime:Number, endTime:Number ):void
		{
			var subtitles:Vector.<SubTitleParser> = activeSubtitles;
			var subtitleCount:int = subtitles.length;
			var potentials:Vector.<TextTrackCue> = new Vector.<TextTrackCue>();

			for ( var i:int = 0; i < subtitleCount; i++ )
			{
				var subtitle:SubTitleParser = subtitles[ i ];
				if ( subtitle.startTime > endTime ) continue;
				if ( subtitle.endTime < startTime ) continue;
				var cues:Vector.<TextTrackCue> = subtitle.textTrackCues;
				var cueCount:int = cues.length;

				for ( var j:int = 0; j < cueCount; j++ )
				{
					var cue:TextTrackCue = cues[ j ];
					if ( cue.startTime > endTime ) break;
					else if ( cue.startTime >= startTime )
					{
						potentials.push(cue);
					}
				}
			}

			if(potentials.length > 0)
			{
				// TODO: Add support for trackid
				cue = potentials[potentials.length - 1];
				if(cue != _lastCue)
				{
					dispatchEvent(new SubtitleEvent(cue.startTime, cue.text, language));

					_lastInjectedSubtitleTime = cue.startTime;
					_lastCue = cue;						
				}
			}

			// Force last time so we eventually show proper subtitles.
			_lastInjectedSubtitleTime = endTime;

		}

		/**
		 * Fired intermittently to check for new subtitle segments to download.
		 */
		private static function onReloadTimer(e:Event):void
		{
			// Check for any subtitles that have not been requested yet.
			if(activeTrait == null || activeTrait.activeManifest == null)
			{
				trace("SubTitleTrait - skipping reload, inactive")
				return;
			}

			// If reloading but not parsed yet.
			if(activeReload && activeReload.timestamp == -1)
			{
				trace("SubTitleTrait - skipping reload, pending download");
				return;
			}

			// Or it's a VOD or was recently reloaded.
			var man:HLSManifestParser = activeTrait.activeManifest;
			if(man && 
				(man.streamEnds
				|| (getTimer() - man.lastReloadRequestTime) < man.targetDuration * 1000 * 0.75))
			{
				trace("SubTitleTrait - skipping reload, waiting until targetDuration has expired.");
				return;
			}

			if(man)
			{
				trace("Saw manifest with age " + (getTimer() - man.lastReloadRequestTime) + " and targetDuration " + man.targetDuration * 1000 );
			}

			trace("SubTitleTrait - initiating reload of " + man.fullUrl);
			var manifest:HLSManifestParser = new HLSManifestParser();
			manifest.addEventListener(Event.COMPLETE, onManifestReloaded);
			manifest.addEventListener(IOErrorEvent.IO_ERROR, onManifestReloadFail);
			manifest.type = HLSManifestParser.SUBTITLES;
			manifest.reload(man);
			activeReload = manifest;
			reloadLanguage = activeTrait.language;
		}

		private static function onManifestReloaded(e:Event):void
		{
			if(e.target != activeReload || reloadLanguage != activeTrait.language)
			{
				trace("Got subtitle manifest reload for non-active manifest, ignoring...");
				return;
			}

			// Instate the manifest.
			trace("Subtitle manifest downloaded, instating " + reloadLanguage);
			activeTrait.instateNewManifest(reloadLanguage, e.target as HLSManifestParser);
			activeReload = null;
			reloadLanguage = null;
		}

		private static function onManifestReloadFail(e:Event):void
		{
			if(e.target != activeReload || reloadLanguage != activeTrait.language)
			{
				trace("Got subtitle manifest reload for non-active manifest, ignoring...");
				return;
			}

			trace("Subtitle manifest failed, clearing reload attempt.");
			activeReload = null;
			reloadLanguage = null;
		}

		protected function instateNewManifest(lang:String, man:HLSManifestParser):void
		{
			if(language != lang)
				return;

			if ( _language == "" ) return;
			for ( var i:int = 0; i < _playLists.length; i++ )
			{
				// If the playlist has a language associated with it, use that language
				var pLanguage:String;
				if (_playLists[ i ].language && _playLists[ i ].language != "")
					pLanguage = _playLists[ i ].language;
				else
					pLanguage = _playLists[ i ].name;
				
				if (pLanguage == _language ) 
				{
					_playLists[ i ].manifest = man;
				}
			}			
		}
		
		public function set playLists( value:Vector.<HLSManifestPlaylist> ):void
		{
			_playLists.length = 0;
			_languages.length = 0;
			
			if ( !value ) return;
			
			for ( var i:int = 0; i < value.length; i++ )
			{
				_playLists.push( value[ i ] );
				if (value[ i ].language && value[ i ].language != "")
					_languages.push( value[ i ].language );
				else
					_languages.push( value[ i ].name );
			}
		}
		
		public function set language( value:String ):void
		{
			// No special logic required, we will sort it out elsewhere.
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
		
		public function get activeManifest():HLSManifestParser
		{
			if ( _language == "" ) return null;
			for ( var i:int = 0; i < _playLists.length; i++ )
			{
				// If the playlist has a language associated with it, use that language
				var pLanguage:String;
				if (_playLists[ i ].language && _playLists[ i ].language != "")
					pLanguage = _playLists[ i ].language;
				else
					pLanguage = _playLists[ i ].name;
				
				if (pLanguage == _language ) return _playLists[ i ].manifest;
			}
			return null;			
		}

		public function get activeSubtitles():Vector.<SubTitleParser>
		{
			var man:HLSManifestParser = activeManifest;
			if(man)
				return man.subtitles;
			return null;
		}
	}
}