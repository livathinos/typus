require "typus/format"

class Admin::ResourcesController < Admin::BaseController

  include Typus::Format

  before_filter :get_model

  before_filter :get_object,
                :only => [ :show,
                           :edit, :update, :destroy, :toggle,
                           :position, :relate, :unrelate,
                           :detach ]

  before_filter :check_resource_ownership,
                :only => [ :edit, :update, :destroy, :toggle,
                           :position, :relate, :unrelate ]

  before_filter :check_if_user_can_perform_action_on_user,
                :only => [ :edit, :update, :toggle, :destroy ]
  before_filter :check_if_user_can_perform_action_on_resources

  before_filter :set_order,
                :only => [ :index ]
  before_filter :set_fields,
                :only => [ :index, :new, :edit, :create, :update, :show, :detach ]

  ##
  # This is the main index of the model. With filters, conditions and more.
  #
  # By default application can respond_to html, csv and xml, but you can add
  # your formats.
  #
  def index
    @conditions, @joins = @resource.build_conditions(params)
    check_resource_ownerships if @resource.typus_options_for(:only_user_items)

    get_objects

    respond_to do |format|
      format.html { generate_html and select_template }
      @resource.typus_export_formats.each { |f| format.send(f) { send("generate_#{f}") } }
    end
  end

  def new
    check_ownership_of_referal_item

    item_params = params.dup
    rejections = %w(controller action resource resource_id back_to selected)
    item_params.delete_if { |k, v| rejections.include?(k) }

    @item = @resource.new(item_params)

    select_template
  end

  ##
  # Create new items. There's an special case when we create an item from
  # another item. In this case, after the item is created we also create the
  # relationship between these items.
  #
  def create
    @item = @resource.new(params[@object_name])

    set_attributes_on_create

    if @item.valid?
      create_with_back_to and return if params[:back_to]
      @item.save
      redirect_on_success
    else
      select_template(:new)
    end
  end

  def edit
    select_template
  end

  def show
    check_resource_ownership and return if @resource.typus_options_for(:only_user_items)
    select_template
  end

  def update
    if @item.update_attributes(params[@object_name])
      set_attributes_on_update
      reload_locales
      redirect_on_success
    else
      select_template(:edit)
    end
  end

  def detach
    if @item.update_attributes(params[:attribute] => nil)
      redirect_on_success
    else
      select_template(:edit)
    end
  end

  def destroy
    @item.destroy
    notice = _t("%{model} successfully removed.", :model => @resource.model_name.human)
    redirect_to set_path, :notice => notice
  end

  def toggle
    @item.toggle(params[:field])
    @item.save!

    notice = _t("%{model} %{attribute} changed.",
               :model => @resource.model_name.human,
               :attribute => params[:field].humanize.downcase)

    redirect_to set_path, :notice => notice
  end

  ##
  # Change item position. This only works if acts_as_list is installed. We can
  # then move items:
  #
  #   params[:go] = 'move_to_top'
  #
  # Available positions are move_to_top, move_higher, move_lower, move_to_bottom.
  #
  def position
    @item.send(params[:go])
    notice = _t("Record moved %{to}.", :to => params[:go].gsub(/move_/, '').humanize.downcase)
    redirect_to set_path, :notice => notice
  end

  ##
  # Relate a model object to another, this action is used only by the
  # has_and_belongs_to_many and has_many relationships.
  #
  def relate
    resource_class = params[:related][:model].typus_constantize
    resource_tableized = params[:related][:model].tableize

    if @item.send(resource_tableized) << resource_class.find(params[:related][:id])
      flash[:notice] = _t("%{model_a} related to %{model_b}",
                         :model_a => resource_class.model_name.human,
                         :model_b => @resource.model_name.human)
    else
      flash[:alert] = _t("%{model_a} cannot be related to %{model_b}",
                         :model_a => resource_class.model_name.human,
                         :model_b => @resource.model_name.human)
    end

    redirect_to set_path
  end

  ##
  # Remove relationship between models, this action never removes items!
  #
  def unrelate
    resource_class = params[:resource].typus_constantize
    resource_tableized = params[:resource].tableize
    resource = resource_class.find(params[:resource_id])

    # We consider that we are unrelating a has_many or has_and_belongs_to_many

    reflection = @resource.reflect_on_association(resource_class.table_name.to_sym)
    macro = reflection.try(:macro)
    options = reflection.try(:options)

    case macro
    # when :has_one
    #   attribute = resource_tableized.singularize
    #   saved_succesfully = @item.update_attribute attribute, nil
    when :has_many
      if options.has_key?(:as) # We are in a polymorphic relationship
        interface = options[:as]
        saved_succesfully = resource.update_attributes("#{interface}_type" => nil, "#{interface}_id" => nil)
      elsif options.has_key?(:through)
        resource_parent = reflection.active_record.find(params[:id])
        saved_succesfully = resource_parent.send(resource_tableized).delete(resource)
      else
        # We have to verify we can unrelate. For example: A Category which has
        # many posts and Post validates_presence_of Category should not be removed.
        attribute = @resource.table_name.singularize
        saved_succesfully = resource.update_attributes(attribute => nil)
      end
    when :has_and_belongs_to_many
      attribute = resource_tableized
      saved_succesfully = @item.send(attribute).delete(resource)
    else
      saved_succesfully = false
    end

    if saved_succesfully
      flash[:notice] = _t("%{model_a} unrelated from %{model_b}",
                         :model_a => resource_class.model_name.human,
                         :model_b => @resource.model_name.human)
    else
      flash[:alert] = _t("%{model_a} cannot be unrelated from %{model_b}",
                        :model_a => resource_class.model_name.human,
                        :model_b => @resource.model_name.human)
    end

    redirect_to set_path
  end

  private

  def get_model
    @resource = params[:controller].extract_class
    @object_name = ActiveModel::Naming.singular(@resource)
  end

  def set_scope
    @resource.unscoped
  end

  def get_object
    @item = set_scope.find(params[:id])
  end

  def get_objects
    eager_loading = @resource.reflect_on_all_associations(:belongs_to).reject { |i| i.options[:polymorphic] }.map { |i| i.name }
    @items = set_scope.joins(@joins).where(@conditions).order(set_order).includes(eager_loading)
  end

  def set_fields
    mapping = case params[:action]
              when "index" then :list
              when "new", "edit", "create", "update" then :form
              else params[:action]
              end

    @fields = @resource.typus_fields_for(mapping)
  end

  def set_order
    params[:sort_order] ||= "desc"
    params[:order_by] ? "#{@resource.table_name}.#{params[:order_by]} #{params[:sort_order]}" : @resource.typus_order_by
  end

  def redirect_on_success
    action = @resource.typus_options_for(:action_after_save)

    case params[:action]
    when "create"
      path = { :action => action }
      path.merge!(:id => @item.id) unless action.eql?("index")
      notice = _t("%{model} successfully created.", :model => @resource.model_name.human)
    when "update", "detach"
      path = case action
             when "index"
               params[:back_to] ? "#{params[:back_to]}##{@resource.to_resource}" : { :action => action }
             else
               { :action => action,
                 :id => @item.id,
                 :back_to => params[:back_to] }
             end
      notice = _t("%{model} successfully updated.", :model => @resource.model_name.human)
    end

    redirect_to path, :notice => notice
  end

  ##
  # When <tt>params[:back_to]</tt> is defined this action is used.
  #
  # - <tt>has_and_belongs_to_many</tt> relationships.
  # - <tt>has_many</tt> relationships (polymorphic ones).
  #
  def create_with_back_to
    if params[:resource] && params[:resource_id]
      resource_class = params[:resource].typus_constantize
      resource_id = params[:resource_id]
      resource = resource_class.find(resource_id)
      association = @resource.reflect_on_association(params[:resource].to_sym).macro rescue :polymorphic
    else
      association = :has_many
    end

    case association
    when :belongs_to
      @item.save
    when :has_and_belongs_to_many
      @item.save
      @item.send(params[:resource]) << resource
    when :has_many
      @item.save
      message = _t("%{model} successfully created.", :model => @resource.model_name.human)
      path = "#{params[:back_to]}?#{params[:selected]}=#{@item.id}"
    when :polymorphic
      resource.send(@item.class.to_resource).create(params[@object_name])
    end

    flash[:notice] = message || _t("%{model_a} successfully assigned to %{model_b}.",
                                  :model_a => @item.class.model_name.human,
                                  :model_b => resource_class.model_name.human)

    redirect_to path || params[:back_to]
  end

  def select_template(action = params[:action], resource = @resource.to_resource)
    folder = File.exist?("app/views/admin/#{resource}/#{action}.html.erb") ? resource : 'resources'
    render "admin/#{folder}/#{action}"
  end

end