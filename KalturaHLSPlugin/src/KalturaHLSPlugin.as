package
{
	import com.kaltura.hls.HLSPluginInfo;
	import com.kaltura.hls.manifest.HLSManifestParser;
    import com.kaltura.kdpfl.model.MediaProxy;
    import com.kaltura.kdpfl.plugin.IPlugin;
    import com.kaltura.kdpfl.plugin.IPluginFactory;
    import flash.utils.getDefinitionByName;
    
    import org.osmf.events.MediaFactoryEvent;
    import org.osmf.media.MediaFactory;
    import org.osmf.media.MediaResourceBase;
    import org.osmf.media.PluginInfoResource;
    import org.puremvc.as3.interfaces.IFacade;
    import com.kaltura.kdpfl.plugin.KPluginEvent;
	import com.kaltura.kdpfl.plugin.KalturaHLSMediator;
	
	import com.kaltura.kdpfl.model.ConfigProxy;
	
	import flash.display.Sprite;
	
	import org.osmf.media.PluginInfo;
    import flash.system.Security;
    
	public class KalturaHLSPlugin extends Sprite implements IPluginFactory, IPlugin
	{
		private var _pluginInfo:HLSPluginInfo;
        private static const HLS_PLUGIN_INFO:String = "com.kaltura.hls.HLSPluginInfo";
		private var _pluginResource:MediaResourceBase;

		private var _segmentBuffer:int = -1;
        
        public function KalturaHLSPlugin()
        {
            Security.allowDomain("*");
            _pluginInfo = new HLSPluginInfo();	
        }
        
		public function get segmentBuffer():int
		{
			return _segmentBuffer;
		}

		public function set segmentBuffer(value:int):void
		{
			_segmentBuffer = value;
		}

        public function create (pluginName : String =null) : IPlugin
        {
            return this;
        }
        
        public function initializePlugin(facade:IFacade):void
        {
			var mediator:KalturaHLSMediator = new KalturaHLSMediator();
			facade.registerMediator(mediator);
			
            //Getting Static reference to Plugin.
            var pluginInfoRef:Class = getDefinitionByName(HLS_PLUGIN_INFO) as Class;
			_pluginResource = new PluginInfoResource(new pluginInfoRef);
            
            var mediaFactory:MediaFactory = (facade.retrieveProxy(MediaProxy.NAME) as MediaProxy).vo.mediaFactory;
            mediaFactory.addEventListener(MediaFactoryEvent.PLUGIN_LOAD, onOSMFPluginLoaded);
            mediaFactory.addEventListener(MediaFactoryEvent.PLUGIN_LOAD_ERROR, onOSMFPluginLoadError);
            mediaFactory.loadPlugin(_pluginResource);		
        }
        
        /**
         * Listener for the LOAD_COMPLETE event.
         * @param e - MediaFactoryEvent
         * 
         */		
        protected function onOSMFPluginLoaded (e : MediaFactoryEvent) : void
        {
			if ( e.resource && e.resource == _pluginResource ) {
				e.target.removeEventListener(MediaFactoryEvent.PLUGIN_LOAD, onOSMFPluginLoaded);
				if (segmentBuffer != -1) 
					HLSManifestParser.MAX_SEG_BUFFER = segmentBuffer;
				dispatchEvent( new KPluginEvent (KPluginEvent.KPLUGIN_INIT_COMPLETE) );
			}
            
        }
        /**
         * Listener for the LOAD_ERROR event.
         * @param e - MediaFactoryEvent
         * 
         */		
        protected function onOSMFPluginLoadError (e : MediaFactoryEvent) : void
        {
			if ( e.resource && e.resource == _pluginResource ) {
	            e.target.removeEventListener(MediaFactoryEvent.PLUGIN_LOAD_ERROR, onOSMFPluginLoadError);
	            dispatchEvent( new KPluginEvent (KPluginEvent.KPLUGIN_INIT_FAILED) );
			}
        }
        
        public function setSkin(styleName:String, setSkinSize:Boolean=false):void
        {
            // Do nothing here
        }
		
		public function get pluginInfo():PluginInfo
		{
			return _pluginInfo;
		}
	}
}