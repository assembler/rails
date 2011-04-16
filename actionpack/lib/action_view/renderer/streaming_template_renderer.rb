require 'fiber'

module ActionView
  class StreamingTemplateRenderer < TemplateRenderer #:nodoc:
    # A valid Rack::Body (i.e. it responds to each).
    # It is initialized with a block that, when called, starts
    # rendering the template.
    class Body #:nodoc:
      def initialize(&start)
        @start = start
      end

      def each(&block)
        @start.call(block)
        self
      end
    end

    # For streaming, instead of rendering a given a template, we return a Body
    # object that responds to each. This object is initialized with a block
    # that knows how to render the template.
    def render_template(template, layout_name = nil, locals = {}) #:nodoc:
      return [super] unless template.supports_streaming?

      locals ||= {}
      layout   = layout_name && find_layout(layout_name, locals.keys)

      Body.new do |buffer|
        delayed_render(buffer, template, layout, @view, locals)
      end
    end

    private

    def delayed_render(buffer, template, layout, view, locals)
      # Wrap the given buffer in the StreamingBuffer and pass it to the
      # underlying template handler. Now, everytime something is concatenated
      # to the buffer, it is not appended to an array, but streamed straight
      # to the client.
      output  = ActionView::StreamingBuffer.new(buffer)
      yielder = lambda { |*name| view._layout_for(*name) }

      instrument(:template, :identifier => template.identifier, :layout => layout.try(:virtual_path)) do
        fiber = Fiber.new do
          if layout
            layout.render(view, locals, output, &yielder)
          else
            # If you don't have a layout, just render the thing
            # and concatenate the final result. This is the same
            # as a layout with just <%= yield %>
            output.safe_concat view._layout_for
          end
        end

        # Set the view flow to support streaming. It will be aware
        # when to stop rendering the layout because it needs to search
        # something in the template and vice-versa.
        view._view_flow = StreamingFlow.new(view._view_flow, fiber)

        # Yo! Start the fiber!
        fiber.resume

        # If the fiber is still alive, it means we need something
        # from the template, so start rendering it. If not, it means
        # the layout exited without requiring anything from the template.
        if fiber.alive?
          content = template.render(view, locals, &yielder)

          # Once rendering the template is done, sets its content in the :layout key.
          view._view_flow.set(:layout, content)

          # In case the layout continues yielding, we need to resume
          # the fiber until all yields are handled.
          fiber.resume while fiber.alive?
        end
      end
    end
  end
end
