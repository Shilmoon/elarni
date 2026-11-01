package utils

import (
	"reflect"
	"unsafe"
)

// AccessField accesses an addressable unexported struct field of the exact requested type.
func AccessField[valueType any](obj any, fieldName string) *valueType {
	value := reflect.ValueOf(obj)
	if value.Kind() != reflect.Pointer || value.IsNil() || value.Elem().Kind() != reflect.Struct {
		return nil
	}
	field := value.Elem().FieldByName(fieldName)
	if !field.IsValid() || !field.CanAddr() || field.Type() != reflect.TypeFor[valueType]() {
		return nil
	}
	return (*valueType)(unsafe.Pointer(field.UnsafeAddr()))
}
