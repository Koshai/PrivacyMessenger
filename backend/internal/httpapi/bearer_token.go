package httpapi

import (
	"errors"
	"net/http"
	"strings"
)

var ErrInvalidAuthorization = errors.New(
	"invalid authorization header",
)

func ParseBearerToken(
	header http.Header,
) (string, error) {
	values := header.Values("Authorization")

	if len(values) != 1 {
		return "", ErrInvalidAuthorization
	}

	value := values[0]

	if strings.ContainsAny(value, "\r\n\t,") {
		return "", ErrInvalidAuthorization
	}

	if len(value) < len("Bearer ")+1 ||
		!strings.EqualFold(value[:len("Bearer")], "Bearer") ||
		value[len("Bearer")] != ' ' {
		return "", ErrInvalidAuthorization
	}

	token := value[len("Bearer "):]

	if token == "" ||
		strings.ContainsAny(token, " ") {
		return "", ErrInvalidAuthorization
	}

	return token, nil
}
