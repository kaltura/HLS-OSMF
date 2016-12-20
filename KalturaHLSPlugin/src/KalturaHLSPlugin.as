package
{
	import com.kaltura.hls.HLSPluginInfo;
	import com.kaltura.hls.m2ts.M2TSFileHandler;
	import com.kaltura.hls.m2ts.M2TSNetLoader;
	import com.kaltura.hls.manifest.HLSManifestParser;
	import com.kaltura.kdpfl.model.MediaProxy;
	import com.kaltura.kdpfl.plugin.IPlugin;
	import com.kaltura.kdpfl.plugin.IPluginFactory;
	import com.kaltura.kdpfl.plugin.KPluginEvent;
	import com.kaltura.kdpfl.plugin.KalturaHLSMediator;
	
	import flash.display.Sprite;
	import flash.system.Security;
	import flash.utils.getDefinitionByName;
	
	import org.osmf.events.MediaFactoryEvent;
	import org.osmf.media.MediaFactory;
	import org.osmf.media.MediaResourceBase;
	import org.osmf.media.PluginInfo;
	import org.osmf.media.PluginInfoResource;
	import org.osmf.net.httpstreaming.HLSHTTPStreamDownloader;
	import org.osmf.net.httpstreaming.HLSHTTPStreamSource;
	import org.puremvc.as3.interfaces.IFacade;
    
	public class KalturaHLSPlugin extends Sprite implements IPluginFactory, IPlugin
	{
		private var _pluginInfo:HLSPluginInfo;
        private static const HLS_PLUGIN_INFO:String = "com.kaltura.hls.HLSPluginInfo";
		private var _pluginResource:MediaResourceBase;

		private var _liveSegmentBuffer:int = -1; // Live only - number of segments to download and process before start playing
		private var _initialBufferTime:int = -1; // initial buffer length till the moment the video starts playing
		private var _expandedBufferTime:int = -1; // acctual buffer length while the video is playing
		private var _maxBufferTime:int = -1; // maximum buffer length while the video is playing
		
		private var _minBitrate:int = -1; // minimum bitrate allowed for ABR while the video is playing (will be passed by JS at initial state)
		private var _maxBitrate:int = -1; // maximum bitrate allowed for ABR while the video is playing (will be passed by JS at initial state)
		private var _prefBitrate:int = -1; // prefared bitrate - the video will start playing on this bitrate and stay fixed on it (will be passed by JS at initial state)
		
		private var _forceCropBottomPercent:Number = 0.0; // force crop workaround for Chrome - the value is a percentage of the hight that will be covered by black bunner. The range is between 0 and 1
		
		private var _sendLogs:Boolean = false;
		
		public var maxReliabilityRecordSize:uint = 5;
		public var minReliability:Number = 0.85;
		public var maxUpSwitchLimit:int = 1;
		public var maxDownSwitchLimit:int = 1;
        
        public function KalturaHLSPlugin()
        {
            Security.allowDomain("*");
            _pluginInfo = new HLSPluginInfo();	
        }
        
		public function get liveSegmentBuffer():int
		{
			return _liveSegmentBuffer;
		}

		public function set liveSegmentBuffer(value:int):void
		{
			_liveSegmentBuffer = value;
		}
		
		public function get initialBufferTime():int
		{
			return _initialBufferTime;
		}
		
		public function set initialBufferTime(value:int):void
		{
			_initialBufferTime = value;
		}
		
		public function get expandedBufferTime():int
		{
			return _expandedBufferTime;
		}
		
		public function set expandedBufferTime(value:int):void
		{
			_expandedBufferTime = value;
		}
		
		public function get maxBufferTime():int{
			return _maxBufferTime;
		}
				
		public function set maxBufferTime(value:int):void{
			_maxBufferTime = value;
		}
		
		public function get minBitrate():int{
			return _minBitrate;
		}
		
		public function set minBitrate(value:int):void{
			_minBitrate = value;
		}
		
		public function get maxBitrate():int{
			return _maxBitrate;
		}
		
		public function set maxBitrate(value:int):void{
			_maxBitrate = value;
		}
		
		public function get prefBitrate():int{
			return _prefBitrate;
		}
		
		public function set prefBitrate(value:int):void{
			_prefBitrate = value;
		}
		
		public function get forceCropBottomPercent():Number{
			return _forceCropBottomPercent;
		}
		
		public function set forceCropBottomPercent(value:Number):void{
			_forceCropBottomPercent = value;
		}
		
		public function get sendLogs():Boolean{
			return _sendLogs;
		}
		
		public function set sendLogs(value:Boolean):void{
			_sendLogs = value;
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
			if(this.maxReliabilityRecordSize){
				M2TSNetLoader.MAX_DOWNSWITCH_LIMIT = this.maxReliabilityRecordSize;
			}
			if(this.maxUpSwitchLimit){
				M2TSNetLoader.MAX_UPSWITCH_LIMIT = this.maxUpSwitchLimit;
			}
			if(this.maxDownSwitchLimit){
				M2TSNetLoader.MAX_DOWNSWITCH_LIMIT = this.maxDownSwitchLimit;
			}
			if(this.minReliability){
				M2TSNetLoader.MIN_RELIABILITY = this.minReliability;
			}
			
			
			if ( e.resource && e.resource == _pluginResource ) {
				e.target.removeEventListener(MediaFactoryEvent.PLUGIN_LOAD, onOSMFPluginLoaded);
				if (liveSegmentBuffer != -1){ 
					HLSManifestParser.MAX_SEG_BUFFER = liveSegmentBuffer; // if passed by JS, update static MAX_SEG_BUFFER with the new value (relevant for LIVE only)
				}
				if (initialBufferTime != -1){
					HLSManifestParser.INITIAL_BUFFER_THRESHOLD = initialBufferTime; //Playback will not begin until at least this much data is buffered (in seconds)
				}
				if (expandedBufferTime != -1){
					HLSManifestParser.NORMAL_BUFFER_THRESHOLD = expandedBufferTime; //After we have stalled once, we switch to using this as the minimum buffer period to allow playback. (in seconds)
				}
				if (maxBufferTime != -1){
					HLSManifestParser.MAX_BUFFER_AMOUNT = maxBufferTime; //How many seconds of video data should we keep in the buffer before giving up on downloading for a while
				}
				if (minBitrate != -1){
					HLSManifestParser.MIN_BITRATE = minBitrate; // minimum bitrate allowed for ABR while the video is playing 
				}
				if (maxBitrate != -1){
					HLSManifestParser.MAX_BITRATE = maxBitrate; // maximum bitrate allowed for ABR while the video is playing 
				}
				if (prefBitrate != -1){
					HLSManifestParser.PREF_BITRATE = prefBitrate; // prefared bitrate - the video will start playing on this bitrate and stay fixed on it
				}
			
				if (forceCropBottomPercent > 0.0){
					HLSManifestParser.FORCE_CROP_WORKAROUND_BOTTOM_PERCENT = forceCropBottomPercent; // force crop workaround for Chrome
				}
		
				if (sendLogs){
					M2TSFileHandler.SEND_LOGS = true;
					HLSManifestParser.SEND_LOGS = true;
					HLSHTTPStreamSource.SEND_LOGS = true;
					HLSHTTPStreamDownloader.SEND_LOGS = true;
				}
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