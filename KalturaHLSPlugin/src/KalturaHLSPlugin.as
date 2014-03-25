package
{
	import com.kaltura.hls.HLSPluginInfo;
	
	import flash.display.Sprite;
	
	import org.osmf.media.PluginInfo;
	
	public class KalturaHLSPlugin extends Sprite
	{
		private var _pluginInfo:HLSPluginInfo;
		
		public function KalturaHLSPlugin()
		{
			_pluginInfo = new HLSPluginInfo();	
		}
		
		public function get pluginInfo():PluginInfo
		{
			return _pluginInfo;
		}
	}
}