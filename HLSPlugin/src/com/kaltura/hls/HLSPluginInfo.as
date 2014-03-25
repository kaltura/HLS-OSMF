package com.kaltura.hls
{
	import org.osmf.media.MediaElement;
	import org.osmf.media.MediaFactoryItem;
	import org.osmf.media.PluginInfo;
	
	public class HLSPluginInfo extends PluginInfo
	{
		private var loader:HLSLoader;
		
		protected function getMediaElement():MediaElement 
		{
			return new HLSElement( null, loader );
		}

		public function HLSPluginInfo(mediaFactoryItems:Vector.<MediaFactoryItem>=null, 
									  mediaElementCreationNotificationFunction:Function=null)
		{
			if ( !mediaFactoryItems ) {
				mediaFactoryItems = new Vector.<MediaFactoryItem>();
			}

			var item:MediaFactoryItem;
			
			loader = new HLSLoader();
			item = new MediaFactoryItem(
				"com.kaltura.hls",
				loader.canHandleResource,
				getMediaElement);
			mediaFactoryItems.push(item);
			
			super(mediaFactoryItems, mediaElementCreationNotificationFunction);
		}
	}
}