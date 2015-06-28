package com.kaltura.kdpfl.plugin
{
	import com.kaltura.hls.SubtitleEvent;
	import com.kaltura.hls.SubtitleTrait;
	import com.kaltura.kdpfl.model.MediaProxy;
	import com.kaltura.kdpfl.model.type.NotificationType;
	import com.kaltura.kdpfl.view.controls.KTrace;
	
	import org.osmf.elements.ProxyElement;
	import org.osmf.events.MediaElementEvent;
	import org.osmf.media.MediaElement;
	import org.osmf.net.NetStreamLoadTrait;
	import org.osmf.traits.DVRTrait;
	import org.osmf.traits.DynamicStreamTrait;
	import org.osmf.traits.MediaTraitType;
	import org.puremvc.as3.interfaces.INotification;
	import org.puremvc.as3.patterns.mediator.Mediator;
	
	import org.osmf.net.httpstreaming.HLSHTTPStreamSource;
	import org.osmf.events.HTTPStreamingEvent;
	
	public class KalturaHLSMediator extends Mediator
	{
		public static const NAME:String = "KalturaHLSMediator";
		public static const HLS_END_LIST:String = "hlsEndList";
		public static const HLS_TRACK_SWITCH:String = "doTextTrackSwitch";
		
		private var _mediaProxy:MediaProxy;
		private var _subtitleTrait:SubtitleTrait;
		private var _loadTrait:NetStreamLoadTrait;
		private var _dynamicTrait:DynamicStreamTrait;
		private var _bufferLength:Number;
		private var _droppedFrames:Number;
		
		public function KalturaHLSMediator( viewComponent:Object=null)
		{
			super(NAME, viewComponent);
		}
		
		override public function onRegister():void
		{
			_mediaProxy = facade.retrieveProxy(MediaProxy.NAME) as MediaProxy;
			super.onRegister();
			

		}
		
		override public function listNotificationInterests():Array
		{
			return [
				NotificationType.DURATION_CHANGE,
				NotificationType.MEDIA_ELEMENT_READY,
				NotificationType.MEDIA_LOADED,
				HLS_TRACK_SWITCH
			];
		}
		
		
		override public function handleNotification(notification:INotification):void
		{
			if ( notification.getName() == NotificationType.DURATION_CHANGE ) {
				if ( _mediaProxy.vo.isLive && _mediaProxy.vo.media.hasTrait(MediaTraitType.DVR) ) {
					var dvrTrait:DVRTrait = _mediaProxy.vo.media.getTrait(MediaTraitType.DVR) as DVRTrait;
					//recording stopped - endlist
					if ( !dvrTrait.isRecording ) {
						sendNotification( HLS_END_LIST );
					}
				} 
			}
			
			if ( notification.getName() == NotificationType.MEDIA_ELEMENT_READY ) {
				_mediaProxy.vo.media.addEventListener(MediaElementEvent.TRAIT_ADD, onTraitAdd); // catch and save relevant traits the moment video object is ready
			}
			
			if ( notification.getName() == HLS_TRACK_SWITCH ) { //trigered by JS changeEmbeddedTextTrack helper in order to change language
				if ( _subtitleTrait && notification.getBody() && notification.getBody().hasOwnProperty("textIndex"))
					_subtitleTrait.language = _subtitleTrait.languages[ notification.getBody().textIndex ]; // change the language index inside subtitleTrait reference of video object
				else
					KTrace.getInstance().log("KalturaHLSMediator :: doTextTrackSwitch >> subtitleTrait or textIndex error.");
			}
			
			if ( NotificationType.MEDIA_LOADED ){
				//get debug info, if exists
				var media : MediaElement = _mediaProxy.vo.media;
				while (media is ProxyElement)
				{
					media = (media as ProxyElement).proxiedElement;
				} 
				if (media.hasOwnProperty("client") && media["client"]) {
					media["client"].addHandler( "hlsDebug", handleHLSDebug );
				}
				HLSHTTPStreamSource.debugBus.addEventListener(HTTPStreamingEvent.BEGIN_FRAGMENT, handleDebugBusEvents);
				HLSHTTPStreamSource.debugBus.addEventListener(HTTPStreamingEvent.END_FRAGMENT, handleDebugBusEvents);
			}
			
		}
		
		protected function onTraitAdd(event:MediaElementEvent):void
		{
			switch (event.traitType) {
				case MediaTraitType.DYNAMIC_STREAM:
					setupDynamicStreamTrait(_mediaProxy.vo.media.getTrait(MediaTraitType.DYNAMIC_STREAM) as DynamicStreamTrait);
					break;
				case MediaTraitType.LOAD:
					setupLoadTrait(_mediaProxy.vo.media.getTrait(MediaTraitType.LOAD) as NetStreamLoadTrait);
					break;
				case SubtitleTrait.TYPE:
					setupSubtitleTrait(_mediaProxy.vo.media.getTrait( SubtitleTrait.TYPE ) as SubtitleTrait);
					break;
			}
			
			if ( _subtitleTrait && _loadTrait && _dynamicTrait ){
				_mediaProxy.vo.media.removeEventListener(MediaElementEvent.TRAIT_ADD, onTraitAdd);
			}
		}
		
		protected function setupSubtitleTrait(trait:SubtitleTrait):void
		{
			_subtitleTrait = trait; // save SubtitleTrait in order to read languages
			if ( _subtitleTrait && _subtitleTrait.languages.length > 0 )
			{
				var langArray:Array = new Array();
				var i:int = 0;
				while (i < _subtitleTrait.languages.length){
					langArray.push({"label":_subtitleTrait.languages[i], "index": i++}); // build languages array in a format that JS expects to receive
				}
				_subtitleTrait.addEventListener(SubtitleEvent.CUE, sendSubtitleNotification); 
				sendNotification("textTracksReceived", {languages:langArray}); //will triger ClosedCaptions textTracksReceived function, through kplayer onTextTracksReceived listener
			}	
		}
		//var trait:NetStreamLoadTrait = element.getTrait(MediaTraitType.LOAD) as NetStreamLoadTrait;
		protected function setupLoadTrait(trait:NetStreamLoadTrait):void
		{
			_loadTrait = trait;
			if (!trait)
				return;
			
			_bufferLength = trait.netStream.bufferLength | 0;
			_droppedFrames = trait.netStream.info.droppedFrames;
		}
		
		protected function setupDynamicStreamTrait(trait:DynamicStreamTrait):void
		{
			_dynamicTrait = trait;
		}
		
		protected function sendHLSDebug(debugInfo:Object):void
		{
			//check for buffer and droppedFrames values
			if ( _bufferLength != _loadTrait.netStream.bufferLength ){
				_bufferLength = _loadTrait.netStream.bufferLength;
				debugInfo['bufferLength'] = _bufferLength;
			}
			
			if ( _droppedFrames != _loadTrait.netStream.info.droppedFrames ){
				_droppedFrames = _loadTrait.netStream.info.droppedFrames;
				debugInfo['droppedFrames'] = _droppedFrames;
			}
			
			sendNotification("debugInfoReceived", debugInfo);
		}
		
		protected function handleHLSDebug(info:Object):void
		{
			var debugInfo:Object = new Object();
			if( info['type'] == "segmentStart" ){
				debugInfo['info'] = 'Start playing segment';
			}//else if ( info['type'] == "segmentEnd" ){
				//debugInfo['type'] = 'End playing segment';
			//}
			debugInfo['uri'] = info['uri'];
			sendHLSDebug(debugInfo);
		}
		
		protected function handleDebugBusEvents(event:HTTPStreamingEvent):void
		{
			var debugInfo:Object = new Object();
			if( event.type == HTTPStreamingEvent.BEGIN_FRAGMENT ){
				debugInfo['info'] = 'Downloading segment';
			}else if ( event.type == HTTPStreamingEvent.END_FRAGMENT ){
				debugInfo['info'] = 'Finished processing segment';
			}
			debugInfo['uri'] = event.url;
			sendHLSDebug(debugInfo);
		}
		
		protected function sendSubtitleNotification(event:SubtitleEvent):void
		{
			sendNotification("loadEmbeddedCaptions", {language: event.language, text: event.text, trackid: 99}); // will triger onLoadEmbeddedCaptions function inside kplayer
		}
		
	}
}