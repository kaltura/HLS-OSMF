package com.kaltura.kdpfl.plugin
{
	import com.kaltura.hls.SubtitleTrait;
	import com.kaltura.kdpfl.model.MediaProxy;
	import com.kaltura.kdpfl.model.type.NotificationType;
	import com.kaltura.kdpfl.view.controls.KTrace;
	
	import org.osmf.events.MediaElementEvent;
	import org.osmf.traits.DVRTrait;
	import org.osmf.traits.MediaTraitType;
	import org.puremvc.as3.interfaces.INotification;
	import org.puremvc.as3.patterns.mediator.Mediator;
	
	public class KalturaHLSMediator extends Mediator
	{
		public static const NAME:String = "KalturaHLSMediator";
		public static const HLS_END_LIST:String = "hlsEndList";
		public static const HLS_TRACK_SWITCH:String = "doTextTrackSwitch";
		
		private var _mediaProxy:MediaProxy;
		private var _subtitleTrait:SubtitleTrait;
		
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
				_mediaProxy.vo.media.addEventListener(MediaElementEvent.TRAIT_ADD, getSubtitleTrait);
			}
			
			if ( notification.getName() == HLS_TRACK_SWITCH ) {
				if ( _subtitleTrait && notification.getBody() && notification.getBody().hasOwnProperty("textIndex"))
					_subtitleTrait.language = _subtitleTrait.languages[ notification.getBody().textIndex ];
				else
					KTrace.getInstance().log("KalturaHLSMediator :: doTextTrackSwitch >> subtitleTrait or textIndex error.");
			}
			
		}
		
		protected function getSubtitleTrait(event:MediaElementEvent):void
		{
			if(event.traitType == SubtitleTrait.TYPE){
				_mediaProxy.vo.media.removeEventListener(MediaElementEvent.TRAIT_ADD, getSubtitleTrait);
				_subtitleTrait = _mediaProxy.vo.media.getTrait( SubtitleTrait.TYPE ) as SubtitleTrait;
				if ( _subtitleTrait && _subtitleTrait.languages.length > 0 )
				{
					var langArray:Array = new Array();
					var i:int = 0;
					while (i < _subtitleTrait.languages.length){
						langArray.push({"label":_subtitleTrait.languages[0], "index": i++});
					}
					
					sendNotification("textTracksReceived", {languages:langArray});
				}	
			}
		}		
		
	}
}