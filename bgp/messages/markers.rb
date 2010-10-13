require 'bgp/messages/update'
module BGP
  def Update.end_of_rib_marker(*args)
    if args.empty?
      Update.new(Path_attribute.new()) if args.empty?
    elsif args[0].is_a?(Hash)
      Update.new(Path_attribute.new(Mp_unreach.new(*args)))
    end
  end
end
