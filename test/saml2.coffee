_             = require 'underscore'
assert        = require 'assert'
async         = require 'async'
crypto        = require 'crypto'
fs            = require 'fs'
saml2         = require "#{__dirname}/../index"
url           = require 'url'
util          = require 'util'
xmldom        = require 'xmldom'

describe 'saml2', ->
  get_test_file = (filename) ->
    fs.readFileSync("#{__dirname}/data/#{filename}").toString()

  dom_from_test_file = (filename) ->
    (new xmldom.DOMParser()).parseFromString get_test_file filename

  before =>
    @good_response_dom = dom_from_test_file "good_response.xml"

  # Auth Request, before it is compressed and base-64 encoded
  describe 'create_authn_request', ->
    it 'contains expected fields', ->
      { id, xml } = saml2.create_authn_request 'https://sp.example.com/metadata.xml', 'https://sp.example.com/assert', 'https://idp.example.com/login'
      dom = (new xmldom.DOMParser()).parseFromString xml
      authn_request = dom.getElementsByTagName('AuthnRequest')[0]

      required_attributes =
        Version: '2.0'
        Destination: 'https://idp.example.com/login'
        AssertionConsumerServiceURL: 'https://sp.example.com/assert'
        ProtocolBinding: 'urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST'

      _(required_attributes).each (req_value, req_name) ->
        assert _(authn_request.attributes).some((attr) -> attr.name is req_name and attr.value is req_value)
        , "Expected to find attribute '#{req_name}' with value '#{req_value}'!"

      assert _(authn_request.attributes).some((attr) -> attr.name is "ID"), "Missing required attribute 'ID'"
      assert.equal dom.getElementsByTagNameNS('urn:oasis:names:tc:SAML:2.0:assertion', 'Issuer')[0].firstChild.data, 'https://sp.example.com/metadata.xml'

    it 'contains an AuthnContext if requested', ->
      { id, xml } = saml2.create_authn_request 'a', 'b', 'c', true, { comparison: 'exact', class_refs: ['context:class']}
      dom = (new xmldom.DOMParser()).parseFromString xml
      authn_request = dom.getElementsByTagName('AuthnRequest')[0]

      requested_authn_context = authn_request.getElementsByTagNameNS('urn:oasis:names:tc:SAML:2.0:protocol', 'RequestedAuthnContext')[0]
      assert _(requested_authn_context.attributes).some (attr) -> attr.name is 'Comparison' and attr.value is 'exact'
      assert.equal requested_authn_context.getElementsByTagNameNS('urn:oasis:names:tc:SAML:2.0:assertion', 'AuthnContextClassRef')[0].firstChild.data, 'context:class'

  describe 'create_metadata', ->
    it 'contains expected fields', ->
      cert = get_test_file 'test.crt'
      cert2 = get_test_file 'test2.crt'

      metadata = saml2.create_metadata 'https://sp.example.com/metadata.xml', 'https://sp.example.com/assert', cert, cert2
      dom = (new xmldom.DOMParser()).parseFromString metadata

      entity_descriptor = dom.getElementsByTagNameNS('urn:oasis:names:tc:SAML:2.0:metadata', 'EntityDescriptor')[0]
      assert _(entity_descriptor.attributes).some((attr) -> attr.name is 'entityID' and attr.value is 'https://sp.example.com/metadata.xml')
        , "Expected to find attribute 'entityID' with value 'https://sp.example.com/metadata.xml'."

      assert _(entity_descriptor.getElementsByTagNameNS('urn:oasis:names:tc:SAML:2.0:metadata', 'AssertionConsumerService')).some((assertion) ->
        _(assertion.attributes).some((attr) -> attr.name is 'Binding' and attr.value is 'urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST') and
          _(assertion.attributes).some((attr) -> attr.name is 'Location' and attr.value is 'https://sp.example.com/assert'))
        , "Expected to find an AssertionConsumerService with POST binding and location 'https://sp.example.com/assert'"

      assert _(entity_descriptor.getElementsByTagNameNS('urn:oasis:names:tc:SAML:2.0:metadata', 'SingleLogoutService')).some((assertion) ->
        _(assertion.attributes).some((attr) -> attr.name is 'Binding' and attr.value is 'urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect') and
          _(assertion.attributes).some((attr) -> attr.name is 'Location' and attr.value is 'https://sp.example.com/assert'))
        , "Expected to find a SingleLogoutService with redirect binding and location 'https://sp.example.com/assert'"

  describe 'format_pem', ->
    it 'formats an unformatted private key', ->
      raw_private_key = (/-----BEGIN PRIVATE KEY-----([^-]*)-----END PRIVATE KEY-----/g.exec get_test_file("test.pem"))[1]
      formatted_key = saml2.format_pem raw_private_key, 'PRIVATE KEY'
      assert.equal formatted_key.trim(), get_test_file("test.pem").trim()

    it 'does not change an already formatted private key', ->
      formatted_key = saml2.format_pem get_test_file("test.pem"), 'PRIVATE KEY'
      assert.equal formatted_key, get_test_file("test.pem")

  describe 'sign_get_request', ->
    it 'correctly signs a get request', ->
      signed = saml2.sign_get_request 'TESTMESSAGE', get_test_file("test.pem")

      verifier = crypto.createVerify 'RSA-SHA256'
      verifier.update 'SAMLRequest=TESTMESSAGE&SigAlg=http%3A%2F%2Fwww.w3.org%2F2001%2F04%2Fxmldsig-more%23rsa-sha256'
      assert verifier.verify(get_test_file("test.crt"), signed.Signature, 'base64'), "Signature is not valid"
      assert signed.SigAlg, 'http://www.w3.org/2001/04/xmldsig-more#rsa-sha256'
      assert signed.SAMLRequest, 'TESTMESSAGE'

  describe 'check_saml_signature', ->
    it 'accepts signed xml', ->
      assert saml2.check_saml_signature(get_test_file("good_assertion.xml"), get_test_file("test.crt"))

    it 'rejects xml without a signature', ->
      assert.equal false, saml2.check_saml_signature(get_test_file("unsigned_assertion.xml"), get_test_file("test.crt"))

    it 'rejects xml with an invalid signature', ->
      assert.equal false, saml2.check_saml_signature(get_test_file("good_assertion.xml"), get_test_file("test2.crt"))

  describe 'check_status_success', =>
    it 'accepts a valid success status', =>
      assert saml2.check_status_success(@good_response_dom), "Did not get 'true' for valid response."

    it 'rejects a missing success status', ->
      assert not saml2.check_status_success(dom_from_test_file("response_error_status.xml")), "Did not get 'false' for invalid response."

    it 'rejects a missing status', ->
      assert not saml2.check_status_success(dom_from_test_file("response_no_status.xml")), "Did not get 'false' for invalid response."

  describe 'pretty_assertion_attributes', ->
    it 'creates a correct user object', ->
      test_attributes =
        "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress": [ "tuser@example.com" ]
        "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name": [ "Test User" ]
        "http://schemas.xmlsoap.org/claims/Group": [ "Test Group" ]

      expected =
        email: "tuser@example.com"
        name: "Test User"
        group: "Test Group"

      assert.deepEqual saml2.pretty_assertion_attributes(test_attributes), expected

  describe 'decrypt_assertion', =>
    it 'decrypts and extracts an assertion', (done) =>
      key = get_test_file("test.pem")
      saml2.decrypt_assertion @good_response_dom, key, (err, result) ->
        assert not err?, "Got error: #{err}"
        assert.equal result, get_test_file("good_response_decrypted.xml")
        done()

    it 'errors if an incorrect key is used', (done) =>
      key = get_test_file("test2.pem")
      saml2.decrypt_assertion @good_response_dom, key, (err, result) ->
        assert (err instanceof Error), "Did not get expected error."
        done()

  describe 'parse_response_header', =>
    it 'correctly parses a response header', =>
      response = saml2.parse_response_header @good_response_dom
      assert.equal response.destination, 'https://sp.example.com/assert'
      assert.equal response.in_response_to, '_1'

    it 'errors if there is no response', ->
      # An assertion is not a response, so this should fail.
      assert.throws -> saml2.parse_response_header dom_from_test_file("good_assertion.xml")

    it 'errors if given a response with the wrong version', ->
      assert.throws -> saml2.parse_response_header dom_from_test_file("response_bad_version.xml")

  describe 'get_name_id', ->
    it 'gets the correct NameID', ->
      name_id = saml2.get_name_id dom_from_test_file('good_assertion.xml')
      assert.equal name_id, 'tstudent'

    it 'parses assertions with explicit namespaces', ->
      name_id = saml2.get_name_id dom_from_test_file('good_assertion_explicit_namespaces.xml')
      assert.equal name_id, 'tstudent'

  describe 'get_session_index', ->
    it 'gets the correct session index', ->
      session_index = saml2.get_session_index dom_from_test_file('good_assertion.xml')
      assert.equal session_index, '_3'

  describe 'parse_assertion_attributes', ->
    it 'correctly parses assertion attributes', ->
      expected_attributes =
          'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/givenname': [ 'Test' ]
          'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress': [ 'tstudent@example.com' ]
          'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/privatepersonalidentifier': [ 'tstudent' ]
          'http://schemas.xmlsoap.org/claims/Group': [ 'CN=Students,CN=Users,DC=idp,DC=example,DC=com' ]
          'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/surname': [ 'Student' ]
          'http://schemas.xmlsoap.org/claims/CommonName': [ 'Test Student' ]

      attributes = saml2.parse_assertion_attributes dom_from_test_file('good_assertion.xml')
      assert.deepEqual attributes, expected_attributes

    it 'correctly parses no assertion attributes', ->
      attributes = saml2.parse_assertion_attributes dom_from_test_file('blank_assertion.xml')
      assert.deepEqual attributes, {}

  # Assert
  describe 'assert', ->
    it 'returns a user object when passed a valid AuthnResponse', (done) ->
      sp = new saml2.ServiceProvider 'https://sp.example.com/metadata.xml', get_test_file('test.pem'), get_test_file('test.crt')
      idp = new saml2.IdentityProvider 'https://idp.example.com/login', 'https://idp.example.com/logout', [ get_test_file('test.crt'), get_test_file('test2.crt') ]

      sp.assert idp, { SAMLResponse: get_test_file("post_response.xml") }, (err, response) ->
        assert not err?, "Got error: #{err}"

        expected_response =
          response_header:
            in_response_to: '_1'
            destination: 'https://sp.example.com/assert'
          type: 'authn_response'
          user:
            name_id: 'tstudent'
            session_index: '_3'
            given_name: 'Test',
            email: 'tstudent@example.com',
            ppid: 'tstudent',
            group: 'CN=Students,CN=Users,DC=idp,DC=example,DC=com',
            surname: 'Student',
            common_name: 'Test Student',
            attributes:
              'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/givenname': [ 'Test' ]
              'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress': [ 'tstudent@example.com' ]
              'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/privatepersonalidentifier': [ 'tstudent' ]
              'http://schemas.xmlsoap.org/claims/Group': [ 'CN=Students,CN=Users,DC=idp,DC=example,DC=com' ]
              'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/surname': [ 'Student' ]
              'http://schemas.xmlsoap.org/claims/CommonName': [ 'Test Student' ]

        assert.deepEqual response, expected_response
        done()

    it 'errors if passed invalid data', (done) ->
      sp = new saml2.ServiceProvider 'https://sp.example.com/metadata.xml', get_test_file('test.pem'), get_test_file('test.crt')
      idp = new saml2.IdentityProvider 'https://idp.example.com/login', 'https://idp.example.com/logout', get_test_file('test.crt')

      sp.assert idp, { SAMLResponse: 'FAIL' }, (err, user) ->
        assert (err instanceof Error), "Did not get expected error."
        done()

  describe 'ServiceProvider', ->
    it 'can be constructed', (done) ->
      sp = new saml2.ServiceProvider 'private_key', 'cert'
      done()

    it 'can create login url', (done) ->
      sp = new saml2.ServiceProvider 'private_key', 'cert'
      idp = new saml2.IdentityProvider 'https://idp.example.com/login', 'https://idp.example.com/logout', 'other_service_cert'

      async.waterfall [
        (cb_wf) -> sp.create_login_url idp, 'https://sp.example.com/assert', cb_wf
      ], (err, login_url, id) ->
        assert not err?, "Error creating login URL: #{err}"
        parsed_url = url.parse login_url, true
        saml_request = parsed_url.query?.SAMLRequest?
        assert saml_request, 'Could not find SAMLRequest in url query parameters'
        done()

    it 'passes through RelayState in login url', (done) ->
      sp = new saml2.ServiceProvider 'private_key', 'cert'
      idp = new saml2.IdentityProvider 'https://idp.example.com/login', 'https://idp.example.com/logout', 'other_service_cert'

      sp.create_login_url idp, 'https://sp.example.com/assert', 'Some Relay State!', (err, login_url, id) ->
        assert not err?, "Error creating login URL: #{err}"
        parsed_url = url.parse login_url, true
        assert.equal parsed_url.query?.RelayState, 'Some Relay State!'
        done()

    it 'can create logout url', (done) ->
      sp = new saml2.ServiceProvider 'https://sp.example.com/metadata.xml', get_test_file('test.pem'), get_test_file('test.crt')
      idp = new saml2.IdentityProvider 'https://idp.example.com/login', 'https://idp.example.com/logout', get_test_file('test.crt')

      async.waterfall [
        (cb_wf) -> sp.create_logout_url idp, 'name_id', 'session_index', cb_wf
      ], (err, logout_url) ->
        assert not err?, "Error creating logout URL: #{err}"
        parsed_url = url.parse logout_url, true
        assert parsed_url?.query?.SAMLRequest?, 'Could not find SAMLRequest in url query parameters'
        assert parsed_url?.query?.Signature?, 'LogoutRequest is not signed'
        done()
