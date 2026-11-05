package messaging

import "testing"

func TestCallKeyBindingContentTypeIsRoutable(t *testing.T) {
	if !IsAllowedContentType(ContentTypeCallKeyBinding) {
		t.Fatal("call-key binding must be an allowed envelope type")
	}
	if IsMLSApplication(ContentTypeCallKeyBinding) {
		t.Fatal("binding type must not be treated as a chat application message")
	}
	if IsAllowedContentType("application/call-key-binding-forged") {
		t.Fatal("unknown content type accepted")
	}
}
