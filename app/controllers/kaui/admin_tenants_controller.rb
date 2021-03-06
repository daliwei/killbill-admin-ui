class Kaui::AdminTenantsController < Kaui::EngineController

  skip_before_filter :check_for_redirect_to_tenant_screen

  def index
    # Display the configured tenants in KAUI (which could be different than the existing tenants known by Kill Bill)
    tenants_for_current_user = retrieve_tenants_for_current_user
    @tenants = Kaui::Tenant.all.select { |tenant| tenants_for_current_user.include?(tenant.kb_tenant_id) }
  end

  def new
    @tenant = Kaui::Tenant.new
  end

  def create
    param_tenant = params[:tenant]

    old_tenant = Kaui::Tenant.find_by_name(param_tenant[:name]) || Kaui::Tenant.find_by_api_key(param_tenant[:api_key])
    if old_tenant
      old_tenant.kaui_allowed_users << Kaui::AllowedUser.where(:kb_username => current_user.kb_username).first_or_create
      redirect_to admin_tenant_path(old_tenant[:id]), :notice => 'Tenant was successfully configured' and return
    end

    begin
      options = tenant_options_for_client
      new_tenant = nil

      begin
        options[:api_key] = param_tenant[:api_key]
        options[:api_secret] = param_tenant[:api_secret]
        new_tenant = Kaui::AdminTenant.find_by_api_key(param_tenant[:api_key], options)
      rescue KillBillClient::API::Unauthorized, KillBillClient::API::NotFound

        # Create the tenant in Kill Bill
        new_tenant = Kaui::AdminTenant.new
        new_tenant.external_key = param_tenant[:name]
        new_tenant.api_key = param_tenant[:api_key]
        new_tenant.api_secret = param_tenant[:api_secret]
        new_tenant = new_tenant.create(false, options[:username], nil, comment, options)
      end

      # Transform object to Kaui model
      tenant_model = Kaui::Tenant.new
      tenant_model.name = param_tenant[:name]
      tenant_model.api_key = param_tenant[:api_key]
      tenant_model.api_secret = param_tenant[:api_secret]
      tenant_model.kb_tenant_id = new_tenant.tenant_id

      # Save in KAUI tables
      tenant_model.save!
      # Make sure at least the current user can access the tenant
      tenant_model.kaui_allowed_users << Kaui::AllowedUser.where(:kb_username => current_user.kb_username).first_or_create
    rescue => e
      flash[:error] = "Failed to create the tenant: #{as_string(e)}"
      redirect_to admin_tenants_path and return
    end

    # Select the tenant, see TenantsController
    session[:kb_tenant_id] = tenant_model.kb_tenant_id
    session[:kb_tenant_name] = tenant_model.name
    session[:tenant_id] = tenant_model.id

    redirect_to admin_tenant_path(tenant_model[:id]), :notice => 'Tenant was successfully configured'
  end

  def show
    @tenant = safely_find_tenant_by_id(params[:id])
    @allowed_users = @tenant.kaui_allowed_users & retrieve_allowed_users_for_current_user

    options = tenant_options_for_client
    options[:api_key] = @tenant.api_key
    options[:api_secret] = @tenant.api_secret

    @catalogs = Kaui::Catalog::get_catalog_json(false, options) rescue @catalogs = []
    @catalogs_xml = Kaui::Catalog::get_catalog_xml(options) rescue @catalogs_xml = []
    @overdue =  Kaui::Overdue::get_overdue_json(options) rescue @overdue = nil
    @overdue_xml = Kaui::Overdue::get_tenant_overdue_config('xml', options) rescue @overdue_xml = nil

    plugin_repository = Kaui::AdminTenant::get_plugin_repository

    @plugin_config =  Kaui::AdminTenant::get_oss_plugin_info(plugin_repository) rescue @plugin_config = ""
    @tenant_plugin_config = Kaui::AdminTenant::get_tenant_plugin_config(plugin_repository, options) rescue @tenant_plugin_config = ""

    # When reloading page from the view, it sends the last tab that was active
    @active_tab = params[:active_tab] || "CatalogShow"
  end

  def upload_catalog
    current_tenant = safely_find_tenant_by_id(params[:id])

    options = tenant_options_for_client
    options[:api_key] = current_tenant.api_key
    options[:api_secret] = current_tenant.api_secret

    uploaded_catalog = params[:catalog]
    catalog_xml = uploaded_catalog.read

    Kaui::AdminTenant.upload_catalog(catalog_xml, options[:username], nil, comment, options)

    redirect_to admin_tenant_path(current_tenant.id), :notice => 'Catalog was successfully uploaded'
  end

  def new_catalog


    @tenant = safely_find_tenant_by_id(params[:id])

    options = tenant_options_for_client
    options[:api_key] = @tenant.api_key
    options[:api_secret] = @tenant.api_secret

    latest_catalog = Kaui::Catalog::get_catalog_json(true, options)

    @ao_mapping = Kaui::Catalog::build_ao_mapping(latest_catalog)

    @available_base_products = latest_catalog && latest_catalog.products ?
        latest_catalog.products.select { |p| p.type == 'BASE' }.map { |p| p.name } : []
    @available_ao_products = latest_catalog && latest_catalog.products ?
        latest_catalog.products.select { |p| p.type == 'ADD_ON' }.map { |p| p.name } : []
    @available_standalone_products = latest_catalog && latest_catalog.products ?
        latest_catalog.products.select { |p| p.type == 'STANDALONE' }.map { |p| p.name } : []
    @product_categories = [:BASE, :ADD_ON, :STANDALONE]
    @billing_period = [:DAILY, :WEEKLY, :BIWEEKLY, :THIRTY_DAYS, :MONTHLY, :QUARTERLY, :BIANNUAL, :ANNUAL, :BIENNIAL]
    @time_units = [:UNLIMITED, :DAYS, :WEEKS, :MONTHS, :YEARS]

    @simple_plan = Kaui::SimplePlan.new
  end

  def new_plan_currency
    @tenant = safely_find_tenant_by_id(params[:id])
    @simple_plan = Kaui::SimplePlan.new
    @simple_plan.plan_id = params[:plan_id]
  end


  def create_simple_plan

    current_tenant = safely_find_tenant_by_id(params[:id])

    options = tenant_options_for_client
    options[:api_key] = current_tenant.api_key
    options[:api_secret] = current_tenant.api_secret

    simple_plan = params.require(:simple_plan).delete_if { |e, value| value.blank? }
    # Fix issue in Rails where first entry in the multi-select array is an empty string
    simple_plan["available_base_products"].reject!(&:blank?) if simple_plan["available_base_products"]

    simple_plan = KillBillClient::Model::SimplePlanAttributes.new(simple_plan)

    Kaui::Catalog.add_tenant_catalog_simple_plan(simple_plan, options[:username], nil, comment, options)

    redirect_to admin_tenant_path(current_tenant.id), :notice => 'Catalog plan was successfully added'
  end

  def new_overdue_config
    @tenant = safely_find_tenant_by_id(params[:id])

    options = tenant_options_for_client
    options[:api_key] = @tenant.api_key
    options[:api_secret] = @tenant.api_secret
    @overdue = Kaui::Overdue::get_overdue_json(options)
  end

  def modify_overdue_config

    current_tenant = safely_find_tenant_by_id(params[:id])

    options = tenant_options_for_client
    options[:api_key] = current_tenant.api_key
    options[:api_secret] = current_tenant.api_secret

    view_form_model = params.require(:kill_bill_client_model_overdue).delete_if { |e, value| value.blank? }
    overdue = Kaui::Overdue::from_overdue_form_model(view_form_model)
    overdue.upload_tenant_overdue_config_json(options[:username], nil, comment, options)
    redirect_to admin_tenant_path(current_tenant.id), :notice => 'Overdue config was successfully added '
  end


  def upload_overdue_config
    current_tenant = safely_find_tenant_by_id(params[:id])

    options = tenant_options_for_client
    options[:api_key] = current_tenant.api_key
    options[:api_secret] = current_tenant.api_secret

    uploaded_overdue_config = params[:overdue]
    overdue_config_xml = uploaded_overdue_config.read

    Kaui::AdminTenant.upload_overdue_config(overdue_config_xml, options[:username], nil, comment, options)

    redirect_to admin_tenant_path(current_tenant.id), :notice => 'Overdue config was successfully uploaded'
  end


  def upload_invoice_template
    current_tenant = safely_find_tenant_by_id(params[:id])

    options = tenant_options_for_client
    options[:api_key] = current_tenant.api_key
    options[:api_secret] = current_tenant.api_secret

    is_manual_pay = params[:manual_pay]
    uploaded_invoice_template = params[:invoice_template]
    invoice_template = uploaded_invoice_template.read

    Kaui::AdminTenant.upload_invoice_template(invoice_template, is_manual_pay, true, options[:username], nil, comment, options)

    redirect_to admin_tenant_path(current_tenant.id), :notice => 'Invoice template was successfully uploaded'
  end

  def upload_invoice_translation
    current_tenant = safely_find_tenant_by_id(params[:id])

    options = tenant_options_for_client
    options[:api_key] = current_tenant.api_key
    options[:api_secret] = current_tenant.api_secret

    locale = params[:translation_locale]
    uploaded_invoice_translation = params[:invoice_translation]
    invoice_translation = uploaded_invoice_translation.read

    Kaui::AdminTenant.upload_invoice_translation(invoice_translation, locale, true, options[:username], nil, comment, options)

    redirect_to admin_tenant_path(current_tenant.id), :notice => 'Invoice translation was successfully uploaded'
  end

  def upload_catalog_translation
    current_tenant = safely_find_tenant_by_id(params[:id])

    options = tenant_options_for_client
    options[:api_key] = current_tenant.api_key
    options[:api_secret] = current_tenant.api_secret

    locale = params[:translation_locale]
    uploaded_catalog_translation = params[:catalog_translation]
    catalog_translation = uploaded_catalog_translation.read

    Kaui::AdminTenant.upload_catalog_translation(catalog_translation, locale, true, options[:username], nil, comment, options)

    redirect_to admin_tenant_path(current_tenant.id), :notice => 'Catalog translation was successfully uploaded'
  end

  def upload_plugin_config
    current_tenant = safely_find_tenant_by_id(params[:id])

    options = tenant_options_for_client
    options[:api_key] = current_tenant.api_key
    options[:api_secret] = current_tenant.api_secret

    plugin_name = params[:plugin_name]
    plugin_properties = params[:plugin_properties]
    plugin_type = params[:plugin_type]

    plugin_config = Kaui::AdminTenant.format_plugin_config(plugin_name, plugin_type, plugin_properties)

    key = plugin_type.present? ? "killbill-#{plugin_name}" : plugin_name
    Kaui::AdminTenant.upload_tenant_plugin_config(key, plugin_config, options[:username], nil, comment, options)

    redirect_to admin_tenant_path(current_tenant.id), :notice => 'Config for plugin was successfully uploaded'
  end

  def remove_allowed_user
    current_tenant = safely_find_tenant_by_id(params[:id])
    au = Kaui::AllowedUser.find(params.require(:allowed_user).require(:id))

    if !current_user.root?
      render :json => {:alert => 'Only the root user can remove users from tenants'}.to_json, :status => 401
      return
    end

    # remove the association
    au.kaui_tenants.delete current_tenant
    render :json => '{}', :status => 200
  end

  def display_catalog_xml
    @catalog_xml = params.require(:xml)
    render xml: @catalog_xml
  end


  def display_overdue_xml
    render xml: params.require(:xml)
  end


  private


  def safely_find_tenant_by_id(tenant_id)
    tenant = Kaui::Tenant.find_by_id(tenant_id)
    raise ActiveRecord::RecordNotFound.new('Could not find tenant ' + tenant_id) unless retrieve_tenants_for_current_user.include?(tenant.kb_tenant_id)
    tenant
  end

  def tenant_options_for_client
    user = current_user
    {
        :username => user.kb_username,
        :password => user.password,
        :session_id => user.kb_session_id
    }
  end

  def comment
    'Multi-tenant Administrative operation'
  end
end
