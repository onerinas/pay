module Pay
  module Stripe
    class Billable
      include Rails.application.routes.url_helpers

      attr_reader :pay_customer

      delegate :processor_id,
        :processor_id?,
        :email,
        :customer_name,
        :payment_method_token,
        :payment_method_token?,
        :stripe_account,
        to: :pay_customer

      def self.default_url_options
        Rails.application.config.action_mailer.default_url_options || {}
      end

      def initialize(pay_customer)
        @pay_customer = pay_customer
      end

      def customer
        stripe_customer = if processor_id?
          ::Stripe::Customer.retrieve(processor_id, stripe_options)
        else
          sc = ::Stripe::Customer.create({email: email, name: customer_name}, stripe_options)
          pay_customer.update!(processor_id: sc.id, stripe_account: stripe_account)
          sc
        end

        if payment_method_token?
          payment_method = ::Stripe::PaymentMethod.attach(payment_method_token, {customer: stripe_customer.id}, stripe_options)
          pay_payment_method = save_payment_method(payment_method, default: false)
          pay_payment_method.make_default!

          pay_customer.payment_method_token = nil
        end

        stripe_customer
      rescue ::Stripe::StripeError => e
        raise Pay::Stripe::Error, e
      end

      def charge(amount, options = {})
        stripe_customer = customer
        args = {
          amount: amount,
          confirm: true,
          confirmation_method: :automatic,
          currency: "usd",
          customer: stripe_customer.id,
          payment_method: stripe_customer.invoice_settings.default_payment_method
        }.merge(options)

        payment_intent = ::Stripe::PaymentIntent.create(args, stripe_options)
        Pay::Payment.new(payment_intent).validate

        charge = payment_intent.charges.first
        Pay::Stripe::Charge.sync(charge.id, object: charge)
      rescue ::Stripe::StripeError => e
        raise Pay::Stripe::Error, e
      end

      def subscribe(name: Pay.default_product_name, plan: Pay.default_plan_name, **options)
        quantity = options.delete(:quantity) || 1
        opts = {
          expand: ["pending_setup_intent", "latest_invoice.payment_intent", "latest_invoice.charge.invoice"],
          items: [plan: plan, quantity: quantity],
          off_session: true
        }.merge(options)

        # Inherit trial from plan unless trial override was specified
        opts[:trial_from_plan] = true unless opts[:trial_period_days]

        # Load the Stripe customer to verify it exists and update payment method if needed
        opts[:customer] = customer.id

        # Create subscription on Stripe
        stripe_sub = ::Stripe::Subscription.create(opts, stripe_options)

        # Save Pay::Subscription
        subscription = Pay::Stripe::Subscription.sync(stripe_sub.id, object: stripe_sub, name: name)

        # No trial, payment method requires SCA
        if subscription.incomplete?
          Pay::Payment.new(stripe_sub.latest_invoice.payment_intent).validate
        end

        subscription
      rescue ::Stripe::StripeError => e
        raise Pay::Stripe::Error, e
      end

      def add_payment_method(payment_method_id, default: false)
        stripe_customer = customer

        return true if payment_method_id == stripe_customer.invoice_settings.default_payment_method

        payment_method = ::Stripe::PaymentMethod.attach(payment_method_id, {customer: stripe_customer.id}, stripe_options)
        ::Stripe::Customer.update(stripe_customer.id, {invoice_settings: {default_payment_method: payment_method.id}}, stripe_options)

        save_payment_method(payment_method, default: default)
      rescue ::Stripe::StripeError => e
        raise Pay::Stripe::Error, e
      end

      # Save the Stripe::PaymentMethod to the database
      def save_payment_method(payment_method, default:)
        pay_payment_method = pay_customer.payment_methods.where(processor_id: payment_method.id).first_or_initialize

        attributes = Pay::Stripe::PaymentMethod.extract_attributes(payment_method).merge(default: default)

        pay_customer.payment_methods.update_all(default: false) if default
        pay_payment_method.update!(attributes)

        # Reload the Rails association
        pay_customer.reload_default_payment_method if default

        pay_payment_method
      end

      def update_email!
        ::Stripe::Customer.update(processor_id, {email: email, name: customer_name}, stripe_options)
      end

      def processor_subscription(subscription_id, options = {})
        ::Stripe::Subscription.retrieve(options.merge(id: subscription_id), stripe_options)
      end

      def invoice!(options = {})
        return unless processor_id?
        ::Stripe::Invoice.create(options.merge(customer: processor_id), stripe_options).pay
      end

      def upcoming_invoice
        ::Stripe::Invoice.upcoming({customer: processor_id}, stripe_options)
      end

      def create_setup_intent
        ::Stripe::SetupIntent.create({customer: processor_id, usage: :off_session}, stripe_options)
      end

      def trial_end_date(stripe_sub)
        # Times in Stripe are returned in UTC
        stripe_sub.trial_end.present? ? Time.at(stripe_sub.trial_end) : nil
      end

      # Syncs a customer's subscriptions from Stripe to the database
      def sync_subscriptions
        subscriptions = ::Stripe::Subscription.list({customer: customer}, stripe_options)
        subscriptions.map do |subscription|
          Pay::Stripe::Subscription.sync(subscription.id)
        end
      rescue ::Stripe::StripeError => e
        raise Pay::Stripe::Error, e
      end

      # https://stripe.com/docs/api/checkout/sessions/create
      #
      # checkout(mode: "payment")
      # checkout(mode: "setup")
      # checkout(mode: "subscription")
      #
      # checkout(line_items: "price_12345", quantity: 2)
      # checkout(line_items [{ price: "price_123" }, { price: "price_456" }])
      # checkout(line_items, "price_12345", allow_promotion_codes: true)
      #
      def checkout(**options)
        args = {
          customer: processor_id,
          payment_method_types: ["card"],
          mode: "payment",
          # These placeholder URLs will be replaced in a following step.
          success_url: options.delete(:success_url) || root_url,
          cancel_url: options.delete(:cancel_url) || root_url
        }

        # Line items are optional
        if (line_items = options.delete(:line_items))
          args[:line_items] = Array.wrap(line_items).map { |item|
            if item.is_a? Hash
              item
            else
              {price: item, quantity: options.fetch(:quantity, 1)}
            end
          }
        end

        ::Stripe::Checkout::Session.create(args.merge(options), stripe_options)
      end

      # https://stripe.com/docs/api/checkout/sessions/create
      #
      # checkout_charge(amount: 15_00, name: "T-shirt", quantity: 2)
      #
      def checkout_charge(amount:, name:, quantity: 1, **options)
        currency = options.delete(:currency) || "usd"
        checkout(
          line_items: {
            price_data: {
              currency: currency,
              product_data: {name: name},
              unit_amount: amount
            },
            quantity: quantity
          },
          **options
        )
      end

      def billing_portal(**options)
        args = {
          customer: processor_id,
          return_url: options.delete(:return_url) || root_url
        }
        ::Stripe::BillingPortal::Session.create(args.merge(options), stripe_options)
      end

      private

      # Options for Stripe requests
      def stripe_options
        {stripe_account: stripe_account}.compact
      end
    end
  end
end
