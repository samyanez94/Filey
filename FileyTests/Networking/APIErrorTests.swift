import Testing

@testable import Filey

struct APIErrorTests {
	@Test func responseErrorsHaveReadableMessages() {
		#expect(APIError.invalidResponse.errorDescription == "The server returned an invalid response.")
		#expect(APIError.unauthorized.errorDescription == "Check the Filey API key in your local configuration.")
		#expect(APIError.invalidData.errorDescription == "The server response didn't match the expected format.")
	}

	@Test func serverErrorIncludesRequestID() {
		let error = APIError.server(statusCode: 503, requestID: "request-123")
		#expect(error.errorDescription == "The request failed with HTTP 503.\nRequest ID: request-123")
	}

	@Test func serverErrorWorksWithoutRequestID() {
		let error = APIError.server(statusCode: 500, requestID: nil)
		#expect(error.errorDescription == "The request failed with HTTP 500.")
	}
}
