import copy


try:
    import dataclasses as _dataclasses

    dataclass = _dataclasses.dataclass
    field = _dataclasses.field
except ImportError:
    _MISSING = object()

    class _FieldSpec(object):
        def __init__(self, default=_MISSING, default_factory=_MISSING):
            self.default = default
            self.default_factory = default_factory

    def field(default=_MISSING, default_factory=_MISSING):
        if default is not _MISSING and default_factory is not _MISSING:
            raise TypeError("cannot specify both default and default_factory")
        return _FieldSpec(default=default, default_factory=default_factory)

    def dataclass(_cls=None, frozen=False):
        def wrap(cls):
            annotations = getattr(cls, "__annotations__", {})
            field_defs = []
            for name in annotations:
                class_value = getattr(cls, name, _MISSING)
                if isinstance(class_value, _FieldSpec):
                    default = class_value.default
                    default_factory = class_value.default_factory
                    if default is not _MISSING:
                        setattr(cls, name, default)
                    elif hasattr(cls, name):
                        delattr(cls, name)
                elif class_value is _MISSING:
                    default = _MISSING
                    default_factory = _MISSING
                else:
                    default = class_value
                    default_factory = _MISSING
                field_defs.append((name, default, default_factory))

            def __init__(self, *args, **kwargs):
                if len(args) > len(field_defs):
                    raise TypeError(
                        "__init__() takes at most %d positional arguments (%d given)"
                        % (len(field_defs), len(args))
                    )

                for index, field_def in enumerate(field_defs):
                    name, default, default_factory = field_def
                    if index < len(args):
                        value = args[index]
                    elif name in kwargs:
                        value = kwargs.pop(name)
                    elif default_factory is not _MISSING:
                        value = default_factory()
                    elif default is not _MISSING:
                        value = copy.deepcopy(default)
                    else:
                        raise TypeError(
                            "__init__() missing required argument: '%s'" % name
                        )

                    if frozen:
                        object.__setattr__(self, name, value)
                    else:
                        setattr(self, name, value)

                if kwargs:
                    raise TypeError(
                        "__init__() got unexpected keyword arguments: %s"
                        % ", ".join(sorted(kwargs.keys()))
                    )

            def __repr__(self):
                parts = []
                for name, _, _ in field_defs:
                    parts.append("%s=%r" % (name, getattr(self, name)))
                return "%s(%s)" % (cls.__name__, ", ".join(parts))

            def __eq__(self, other):
                if type(self) is not type(other):
                    return False
                return all(
                    getattr(self, name) == getattr(other, name)
                    for name, _, _ in field_defs
                )

            cls.__init__ = __init__
            cls.__repr__ = __repr__
            cls.__eq__ = __eq__

            if frozen:
                def _frozen_setattr(self, name, value):
                    raise AttributeError(
                        "cannot assign to field '%s' on frozen dataclass" % name
                    )

                cls.__setattr__ = _frozen_setattr

            return cls

        if _cls is None:
            return wrap
        return wrap(_cls)
