module ApplicationController::AdvancedSearch
  extend ActiveSupport::Concern

  # Build advanced search expression
  def adv_search_build(model)
    # Restore @edit hash if it's saved in @settings
    @expkey = :expression                                               # Reset to use default expression key
    if session[:adv_search] && session[:adv_search][model.to_s]
      adv_search_model = session[:adv_search][model.to_s]
      @edit = copy_hash(adv_search_model[@expkey] ? adv_search_model : session[:edit])
      # default search doesnt exist or if it is marked as hidden
      if @edit && @edit[:expression] && !@edit[:expression][:selected].blank? &&
         !MiqSearch.exists?(@edit[:expression][:selected][:id])
        clear_default_search
      elsif @edit && @edit[:expression] && !@edit[:expression][:selected].blank?
        s = MiqSearch.find(@edit[:expression][:selected][:id])
        clear_default_search if s.search_key == "_hidden_"
      end
      @edit.delete(:exp_token)                                          # Remove any existing atom being edited
    else                                                                # Create new exp fields
      @edit = {}
      @edit[@expkey] ||= Expression.new
      @edit[@expkey][:expression] = {"???" => "???"}                    # Set as new exp element
      @edit[@expkey][:use_mytags] = true                                # Include mytags in tag search atoms
      @edit[:custom_search] = false                                     # setting default to false
      @edit[:new] = {}
      @edit[:new][@expkey] = @edit[@expkey][:expression]                # Copy to new exp
      @edit[@expkey].history.reset(@edit[@expkey][:expression])
      @edit[:adv_search_open] = false
      @edit[@expkey][:exp_model] = model.to_s
    end
    @edit[@expkey][:exp_table] = exp_build_table(@edit[@expkey][:expression]) # Build the table to display the exp
    @edit[:in_explorer] = @explorer # Remember if we're in an explorer

    if @hist && @hist[:qs_exp] # Override qs exp if qs history button was pressed
      @edit[:adv_search_applied] = {:text => @hist[:text], :qs_exp => @hist[:qs_exp]}
      session[:adv_search][model.to_s] = copy_hash(@edit) # Save updated adv_search options
    end
  end

  def adv_search_button_saveid
    if @edit[:new_search_name].nil? || @edit[:new_search_name] == ""
      add_flash(_("Search Name is required"), :error)
      params[:button] = "save" # Redraw the save screen
    else
      s = @edit[@expkey].build_search(@edit[:new_search_name], @edit[:search_type], session[:userid])
      s.filter = MiqExpression.new(@edit[:new][@expkey]) # Set the new expression
      if s.save
        add_flash(_("%{model} search \"%{name}\" was saved") %
          {:model => ui_lookup(:model => @edit[@expkey][:exp_model]),
           :name => @edit[:new_search_name]})
        @edit[@expkey].select_filter(s)
        @edit[:new_search_name] = @edit[:adv_search_name] = @edit[@expkey][:exp_last_loaded][:description] unless @edit[@expkey][:exp_last_loaded].nil?
        @edit[@expkey][:expression] = copy_hash(@edit[:new][@expkey])
        # Build the expression table
        @edit[@expkey][:exp_table] = exp_build_table(@edit[@expkey][:expression])
        @edit[@expkey].history.reset(@edit[@expkey][:expression])
        # Clear the current selected token
        @edit[@expkey][:exp_token] = nil
      else
        s.errors.each do |field, msg|
          add_flash("#{field.to_s.capitalize} #{msg}", :error)
        end
        params[:button] = "save" # Redraw the save screen
      end
    end
  end

  def adv_search_button_loadit
    if @edit[@expkey][:exp_chosen_search]
      @edit[:selected] = true
      s = MiqSearch.find(@edit[@expkey][:exp_chosen_search].to_s)
      @edit[:new][@expkey] = s.filter.exp
      @edit[@expkey].select_filter(s, true)
      @edit[:search_type] = s[:search_type] == 'global' ? 'global' : nil
    elsif @edit[@expkey][:exp_chosen_report]
      r = MiqReport.for_user(current_user).find(@edit[@expkey][:exp_chosen_report].to_s)
      @edit[:new][@expkey] = r.conditions.exp
      @edit[@expkey][:exp_last_loaded] = nil                                # Clear the last search loaded
      @edit[:adv_search_report] = r.name                          # Save the report name
    end
    @edit[:new_search_name] = @edit[:adv_search_name] = @edit[@expkey][:exp_last_loaded].nil? ? nil : @edit[@expkey][:exp_last_loaded][:description]
    @edit[@expkey][:expression] = copy_hash(@edit[:new][@expkey])
    @edit[@expkey][:exp_table] = exp_build_table(@edit[@expkey][:expression])       # Build the expression table
    @edit[@expkey].history.reset(@edit[@expkey][:expression])
    @edit[@expkey][:exp_token] = nil                                        # Clear the current selected token
    add_flash(_("%{model} search \"%{name}\" was successfully loaded") %
      {:model => ui_lookup(:model => @edit[@expkey][:exp_model]), :name => @edit[:new_search_name]})
  end

  def adv_search_button_delete
    s = MiqSearch.find(@edit[@expkey][:selected][:id])              # Fetch the latest record
    id = s.id
    sname = s.description
    begin
      s.destroy                                                   # Delete the record
    rescue => bang
      add_flash(_("%{model} \"%{name}\": Error during 'delete': %{error_message}") %
        {:model => ui_lookup(:model => "MiqSearch"), :name => sname, :error_message => bang.message}, :error)
    else
      if (def_search = settings(:default_search, @edit[@expkey][:exp_model].to_s.to_sym)) # See if a default search exists
        if id.to_i == def_search.to_i
          user_settings = current_user.settings || {}
          user_settings[:default_search].delete(@edit[@expkey][:exp_model].to_s.to_sym)
          current_user.update_attributes(:settings => user_settings)
          @edit[:adv_search_applied] = nil          # clearing up applied search results
        end
      end
      add_flash(_("%{model} search \"%{name}\": Delete successful") %
        {:model => ui_lookup(:model => @edit[@expkey][:exp_model]), :name => sname})
      audit = {:event        => "miq_search_record_delete",
               :message      => "[#{sname}] Record deleted",
               :target_id    => id,
               :target_class => "MiqSearch",
               :userid       => session[:userid]}
      AuditEvent.success(audit)
    end
  end

  def adv_search_button_apply
    @edit[@expkey][:selected] = @edit[@expkey][:exp_last_loaded] # Save the last search loaded (saved)
    @edit[:adv_search_applied] ||= {}
    @edit[:adv_search_applied][:exp] = {}
    adv_search_set_text # Set search text filter suffix
    @edit[:selected] = true
    @edit[:adv_search_applied][:exp] = @edit[:new][@expkey]   # Save the expression to be applied
    @edit[@expkey].exp_token = nil                            # Remove any existing atom being edited
    @edit[:adv_search_open] = false                           # Close the adv search box
    if MiqExpression.quick_search?(@edit[:adv_search_applied][:exp])
      quick_search_show
      return
    else
      @edit[:adv_search_applied].delete(:qs_exp)            # Remove any active quick search
      session[:adv_search] ||= {}                     # Create/reuse the adv search hash
      session[:adv_search][@edit[@expkey][:exp_model]] = copy_hash(@edit) # Save by model name in settings
    end
    if @edit[:in_explorer]
      self.x_node = "root"                                      # Position on root node
      replace_right_cell
    else
      javascript_redirect :action => 'show_list' # redirect to build the list screen
    end
    return
  end

  def adv_search_button_reset_fields
    @edit[@expkey][:expression] = {"???" => "???"}              # Set as new exp element
    @edit[:new][@expkey] = @edit[@expkey][:expression]        # Copy to new exp
    @edit[@expkey].history.reset(@edit[@expkey][:expression])
    @edit[@expkey][:exp_table] = exp_build_table(@edit[@expkey][:expression])       # Rebuild the expression table
    @edit[@expkey][:exp_last_loaded] = nil                    # Clear the last search loaded
    @edit[:adv_search_name] = nil                             # Clear search name
    @edit[:adv_search_report] = nil                           # Clear the report name
    @edit[@expkey][:selected] = nil                           # Clear selected search
  end

  def adv_search_button_rebuild_left_div
    if x_active_tree.to_s == "configuration_manager_cs_filter_tree"
      build_configuration_manager_tree(:configuration_manager_cs_filter, x_active_tree)
      build_accordions_and_trees
      load_or_clear_adv_search
    elsif @edit[:in_explorer] || %w(storage_tree configuration_scripts_tree).include?(x_active_tree.to_s)
      tree_type = x_active_tree.to_s.sub(/_tree/, '').to_sym
      builder = TreeBuilder.class_for_type(tree_type)
      tree = builder.new(x_active_tree, tree_type, @sb)
    elsif %w(ems_cloud ems_infra).include?(@layout)
      build_listnav_search_list(@view.db)
    else
      build_listnav_search_list(@edit[@expkey][:exp_model])
    end

    render :update do |page|
      page << javascript_prologue
      if @edit[:in_explorer] || %w(storage_tree configuration_scripts_tree).include?(x_active_tree.to_s)
        tree_name = x_active_tree.to_s
        page.replace("#{tree_name}_div", :partial => "shared/tree", :locals => {
          :tree => tree,
          :name => tree_name
        })
      else
        page.replace(:listnav_div, :partial => "layouts/listnav")
      end
    end
  end

  # One of the form buttons was pressed on the advanced search panel
  def adv_search_button
    @edit = session[:edit]
    @view = session[:view]

    # setting default to false
    @edit[:custom_search] = false

    case params[:button]
    when "saveit" then adv_search_button_saveid
    when "loadit" then adv_search_button_loadit
    when "delete" then
      adv_search_button_delete
      adv_search_button_reset_fields

    when "reset"
      add_flash(_("The current search details have been reset"), :warning)
      adv_search_button_reset_fields

    when "apply"  then adv_search_button_apply
    when "cancel"
      @edit[@expkey][:exp_table] = exp_build_table(@edit[@expkey][:expression]) # Rebuild the existing expression table
      @edit[@expkey].prefill_val_types
    end

    if params[:button] == "save"
      @edit[:search_type] = nil unless @edit.key?(:search_type)
    end

    if ["delete", "saveit"].include?(params[:button])
      adv_search_button_rebuild_left_div
      return
    end

    render :update do |page|
      page << javascript_prologue
      if ["load", "save"].include?(params[:button])
        display_mode = params[:button]
      else
        @edit[@expkey][:exp_chosen_report] = nil
        @edit[@expkey][:exp_chosen_search] = nil
        display_mode = nil
      end
      page.replace("adv_search_body",   :partial => "layouts/adv_search_body",   :locals => {:mode => display_mode})
      page.replace("adv_search_footer", :partial => "layouts/adv_search_footer", :locals => {:mode => display_mode})
    end
  end

  # One of the load choices was selected on the advanced search load panel
  def adv_search_load_choice
    @edit = session[:edit]
    if params[:chosen_search]
      @edit[@expkey][:exp_chosen_report] = nil
      if params[:chosen_search] == "0"
        @edit[@expkey][:exp_chosen_search] = nil
      else
        @edit[@expkey][:exp_chosen_search] = params[:chosen_search].to_i
        @exp_to_load = exp_build_table(MiqSearch.find(params[:chosen_search]).filter.exp)
      end
    else
      @edit[@expkey][:exp_chosen_search] = nil
      if params[:chosen_report] == "0"
        @edit[@expkey][:exp_chosen_report] = nil
      else
        @edit[@expkey][:exp_chosen_report] = params[:chosen_report].to_i
        @exp_to_load = exp_build_table(MiqReport.for_user(current_user).find(params[:chosen_report]).conditions.exp)
      end
    end
    render :update do |page|
      page << javascript_prologue
      page.replace("adv_search_body", :partial => "layouts/adv_search_body", :locals => {:mode => 'load'})
      page.replace("adv_search_footer", :partial => "layouts/adv_search_footer", :locals => {:mode => 'load'})
    end
  end

  # Character typed into search name field
  def adv_search_name_typed
    @edit = session[:edit]
    @edit[:new_search_name] = params[:search_name] if params[:search_name]
    @edit[:search_type] = params[:search_type].to_s == "1" ? "global" : nil if params[:search_type]
    render :update do |page|
      page << javascript_prologue
    end
  end

  # Clear the applied search
  def adv_search_clear
    respond_to do |format|
      format.js do
        @explorer = true
        if x_active_tree.to_s =~ /_filter_tree$/ &&
           !["Vm", "MiqTemplate"].include?(TreeBuilder.get_model_for_prefix(@nodetype))
          search_id = 0
          if x_active_tree == :configuration_manager_cs_filter_tree || x_active_tree == :automation_manager_cs_filter_tree
            adv_search_build("ConfiguredSystem")
          else
            adv_search_build(vm_model_from_active_tree(x_active_tree))
          end
          session[:edit] = @edit              # Set because next method will restore @edit from session
        end
        listnav_search_selected(search_id)  # Clear or set the adv search filter
        self.x_node = "root"
        replace_right_cell
      end
      format.html do
        @edit = session[:edit]
        @view = session[:view]
        @edit[:adv_search_applied] = nil
        @edit[:expression][:exp_last_loaded] = nil
        session[:adv_search] ||= {}                   # Create/reuse the adv search hash
        session[:adv_search][@edit[@expkey][:exp_model]] = copy_hash(@edit) # Save by model name in settings
        default_search = settings(:default_search, @view.db.to_s.to_sym)
        if default_search.present? && default_search.to_i != 0
          s = MiqSearch.find(default_search)
          @edit[@expkey].select_filter(s)
          @edit[:selected] = false
        else
          @edit[@expkey][:selected] = {:id => 0}
          @edit[:selected] = true     # Set a flag, this is checked whether to load initial default or clear was clicked
        end
        redirect_to(:action => "show_list")
      end
      format.any { head :not_found }  # Anything else, just send 404
    end
  end
end
