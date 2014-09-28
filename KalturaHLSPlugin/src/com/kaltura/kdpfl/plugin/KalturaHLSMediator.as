package com.kaltura.kdpfl.plugin
{
	import org.puremvc.as3.patterns.mediator.Mediator;
	import com.kaltura.kdpfl.model.MediaProxy;
	import com.kaltura.kdpfl.model.type.NotificationType;
	import org.puremvc.as3.interfaces.INotification;
	import org.osmf.traits.MediaTraitType;
	import org.osmf.traits.DVRTrait;
	
	public class KalturaHLSMediator extends Mediator
	{
		public static const NAME:String = "KalturaHLSMediator";
		public static const HLS_END_LIST:String = "hlsEndList";
		
		private var _mediaProxy:MediaProxy;
		
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
				NotificationType.DURATION_CHANGE
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
			
		}
	}
}