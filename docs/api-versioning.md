# API versioning

The API is versioned in the URL (`/api/v1`, [decision 2](decisions.md)). Every response says which version produced it:

```http
API-Version: v1
```

A version that is being retired also says so, using the standard headers, so client libraries and monitoring can notice
long before it stops working:

```http
Deprecation: @1798761600                         # RFC 9745: when it was deprecated (Unix time)
Sunset: Tue, 01 Jun 2027 00:00:00 GMT            # RFC 8594: when it stops working
Link: <https://docs.example.com/v2>; rel="successor-version"
```

The mechanism is `ApiVersioning` (`app/controllers/concerns/api_versioning.rb`), included by each version's `BaseController`.

## What counts as a breaking change

Within a version, these are **not** breaking and ship freely (and go in the [changelog](../CHANGELOG.md)): a new endpoint, a new optional
parameter, a new field in a response, a new enum value *only where documented that clients must tolerate unknown values*, a new error `code`.

These are breaking and need a new version: removing or renaming an endpoint, parameter or field; changing a field's type or meaning;
making an optional parameter required; changing the status code or `code` of an existing error; tightening validation so that
previously valid input is rejected.

## Adding v2

1. **Routes.** In `config/routes.rb` add `namespace :v2` next to `:v1`. Start by re-exporting what has not changed (`resources :projects, controller: "v1/projects"`
   is wrong: share logic, not controllers; see step 3).
2. **Base controller.** `Api::V2::BaseController < ApplicationController` with `include ApiVersioning`, `api_version "v2"` and the same `verify_authorized` / `verify_policy_scoped` callbacks as v1.
3. **Share what is shared.** Policies, models, query objects, forms and commands are version-independent; keep them that way. What
   differs between versions is the *representation*: write `Api::V2::...Resource` Alba classes (or subclass the v1 ones) and the controllers that use them.
   Resist copying a controller to change one field.
4. **Document it.** Add `v2/swagger.yaml` to `config.openapi_specs` in `spec/swagger_helper.rb`; give the rswag specs for v2 the `openapi_spec: "v2/swagger.yaml"` metadata; extend `api_docs_spec` to check both documents.
5. **Isolation sweep.** Add the v2 routes to `spec/requests/tenant_isolation_spec.rb`; its last example will fail until you do.

## Retiring v1

1. Announce it in the changelog and to known clients, with dates.
2. Declare the deprecation: in `Api::V1::BaseController`

   ```ruby
   deprecate_api! on: Date.new(2027, 1, 15), sunset: Date.new(2027, 7, 15), successor: "https://docs.example.com/v2"
   ```

   Every v1 response now carries the three headers.
3. Watch usage by version (the structured request logs carry the path; group by `/api/v1` vs `/api/v2`) and contact whoever still calls v1.
4. After the sunset date, replace v1's controllers with a `410 Gone` (an `ErrorSerializer` response with code `api_version_retired`) for a grace period, then delete them.
