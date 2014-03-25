package net.digitalprimates.osmf.utils
{
	import org.osmf.media.URLResource;
	
	/**
	 * 
	 * 
	 * @author Nathan Weber
	 */
	public class DashResource extends URLResource
	{
		//----------------------------------------
		//
		// Properties
		//
		//----------------------------------------
		
		public var live:Boolean;
		
		//----------------------------------------
		//
		// Constructor
		//
		//----------------------------------------
		
		public function DashResource(url:String, live:Boolean=false) {
			super(url);
			this.live = live;
		}
	}
}