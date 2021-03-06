part of dart_force_mvc_lib;

class ForceRegistry {
  WebApplication webApplication;
  File _basePath;
  HttpMessageRegulator messageRegulator = new HttpMessageRegulator();

  ForceRegistry(this.webApplication) {
    _basePath = new File(Platform.script.toFilePath());

    ApplicationContext.bootstrap();

    ApplicationContext.setBean("HttpMessageRegulator", messageRegulator);
  }

  void loadValues(String path) {
    var valuesUri = new Uri.file(_basePath.path).resolve(path);
    var file = new File(valuesUri.toFilePath());
    var yaml = file.readAsStringSync();

    ApplicationContext.registerMessage(path, yaml);
  }

  void scanning() {
    // scan for controllers
    var classes =
        ApplicationContext.addComponents(new Scanner<_Controller>().scan());

    // scan for restcontrollers
    var rest_classes =
        ApplicationContext.addComponents(new Scanner<_RestController>().scan());

    // scan for controllerAdvicers classes
    var advisers = ApplicationContext.addComponents(
        new Scanner<_ControllerAdvice>().scan());

    List<MetaDataValue<ModelAttribute>> adviserModels =
        new List<MetaDataValue<ModelAttribute>>();
    List<MetaDataValue<ExceptionHandler>> adviserExc =
        new List<MetaDataValue<ExceptionHandler>>();
    for (var obj in advisers) {
      adviserModels
          .addAll(new MetaDataHelper<ModelAttribute, MethodMirror>().from(obj));
      adviserExc.addAll(
          new MetaDataHelper<ExceptionHandler, MethodMirror>().from(obj));
    }

    /* now register all the controller classes */
    for (var obj in classes) {
      this._register(obj, adviserModels, adviserExc);
    }

    /* now register all the controller classes */
    for (var obj in rest_classes) {
      this._register(obj, adviserModels, adviserExc, isRest: true);
    }

    // Search for interceptors
    ClassSearcher<HandlerInterceptor> searcher =
        new ClassSearcher<HandlerInterceptor>();
    List<HandlerInterceptor> interceptorList = searcher.scan();

    webApplication.interceptors.addAll(interceptorList);
  }

  void register(Object obj) {
    _register(obj, new List<MetaDataValue<ModelAttribute>>(),
        new List<MetaDataValue<ExceptionHandler>>());
  }

  void _register(Object obj, List<MetaDataValue<ModelAttribute>> adviserModels,
      List<MetaDataValue<ExceptionHandler>> adviserExc,
      {bool isRest: false}) {
    List<MetaDataValue<RequestMapping>> mirrorValues =
        new MetaDataHelper<RequestMapping, MethodMirror>().from(obj);
    List<MetaDataValue<ModelAttribute>> mirrorModels =
        new MetaDataHelper<ModelAttribute, MethodMirror>().from(obj);
    mirrorModels.addAll(adviserModels);

    var _ref; //Variable to check null values

    // first look if the controller has a @Authentication annotation
    var roles = (_ref =
                new AnnotationScanner<_Authentication>().instanceFrom(obj)) ==
            null
        ? null
        : _ref.roles;
    // then look at PreAuthorizeRoles, when they are defined		     // then look at PreAuthorizeRoles, when they are defined
    roles = (_ref =
                new AnnotationScanner<PreAuthorizeRoles>().instanceFrom(obj)) ==
            null
        ? roles
        : _ref.roles;

    String startPath = (_ref =
                new AnnotationScanner<RequestMapping>().instanceFrom(obj)) !=
            null
        ? _ref.value
        : "";

    for (MetaDataValue mv in mirrorValues) {
      // execute all ! ! !
      PathAnalyzer pathAnalyzer = new PathAnalyzer(mv.object.value);

      UrlPattern urlPattern =
          new UrlPattern("${startPath}${pathAnalyzer.route}");
      this.webApplication.use(urlPattern, (ForceRequest req, Model model) {
        try {
          // prepare model
          model = _prepareModel(model, mirrorModels);

          // Has ResponseStatus in metaData?
          bool hasResponseBody =
              _hasResponseBody(mv.getOtherMetadata(), req) || isRest;

          // search for path variables
          for (var i = 0; pathAnalyzer.variables.length > i; i++) {
            var variableName = pathAnalyzer.variables[i],
                value = urlPattern.parse(req.request.uri.path)[i];
            req.path_variables[variableName] = value;
          }

          List positionalArguments =
              _calculate_positionalArguments(mv, model, req);
          Object obj = _executeFunction(mv, positionalArguments);

          if (hasResponseBody) {
            // model.getData().clear();
            // model.addAttributeObject(obj);
            messageRegulator.loopOverMessageConverters(req, obj);
            return new ResponseDone();
          } else {
            return obj;
          }
        } catch (e, stackTrace) {
          // Look for exceptionHandlers in this case
          print(stackTrace);
          List<MetaDataValue<ExceptionHandler>> mirrorExceptions =
              new MetaDataHelper<ExceptionHandler, MethodMirror>().from(obj);
          mirrorExceptions.addAll(adviserExc);

          return _errorHandling(mirrorExceptions, model, req, e);
        }
      }, method: mv.object.method, roles: roles);
    }
  }

  Model _prepareModel(
      Model model, List<MetaDataValue<ModelAttribute>> mirrorModels) {
    for (MetaDataValue mvModel in mirrorModels) {
      InstanceMirror res = mvModel.invoke([]);

      if (res != null && res.hasReflectee) {
        model.addAttribute(mvModel.object.value, res.reflectee);
      }
    }
    return model;
  }

  bool _hasResponseBody(List otherMetaData, req) {
    bool hasResponseBody = false;

    for (var metaData in otherMetaData) {
      if (metaData is ResponseStatus) {
        ResponseStatus responseStatus = metaData;
        // set response status
        req.statusCode(responseStatus.value);
      }
      if (metaData is _ResponseBody) {
        hasResponseBody = true;
      }
    }
    return hasResponseBody;
  }

  _errorHandling(List<MetaDataValue<ExceptionHandler>> mirrorExceptions,
      Model model, ForceRequest req, e) {
    if (mirrorExceptions.length == 0) {
      throw e;
    } else {
      MetaDataValue<ExceptionHandler> mdvException = null;

      for (MetaDataValue<ExceptionHandler> mdv in mirrorExceptions) {
        if (mdv.object.type != null && e.runtimeType == mdv.object.type) {
          mdvException = mdv;
        }
        if (mdvException == null && mdv.object.type == null) {
          mdvException = mdv;
        }
      }

      if (mdvException != null) {
        List positionalArguments =
            _calculate_positionalArguments(mdvException, model, req, e);
        return _executeFunction(mdvException, positionalArguments);
      } else {
        throw e;
      }
    }
  }

  _executeFunction(MetaDataValue mdv, List positionalArguments) {
    InstanceMirror res = mdv.invoke(positionalArguments);
    return res.reflectee;
  }

  List _calculate_positionalArguments(
      MetaDataValue mv, Model model, ForceRequest req,
      [ex_er]) {
    List positionalArguments = [];
    for (ParameterMirror pm in mv.parameters) {
      String name = (MirrorSystem.getName(pm.simpleName));

      if (pm.type is Model || name == 'model') {
        positionalArguments.add(model);
      } else if (pm.type is ForceRequest || name == 'req') {
        positionalArguments.add(req);
      } else if (pm.type is HttpSession || name == 'session') {
        positionalArguments.add(req.request.session);
      } else if (pm.type is HttpHeaders || name == 'headers') {
        positionalArguments.add(req.request.headers);
      } else if (pm.type is Exception || name == 'exception') {
        positionalArguments.add(ex_er);
      } else if (pm.type is Error || name == 'error') {
        positionalArguments.add(ex_er);
      } else if (pm.type is Intl || name == 'locale') {
        positionalArguments.add(req.locale);
      } else {
        if (req.path_variables[name] != null) {
          positionalArguments.add(req.path_variables[name]);
        } else {
          for (InstanceMirror im in pm.metadata) {
            if (im.reflectee is PathVariable) {
              PathVariable pathVariable = im.reflectee;
              if (req.path_variables[pathVariable.value] != null) {
                positionalArguments.add(req.path_variables[pathVariable.value]);
              }
            }
            if (im.reflectee is RequestParam) {
              RequestParam rp = im.reflectee;
              String qvalue = (rp.value == "" ? name : rp.value);
              if (req.request.uri.queryParameters[qvalue] != null) {
                positionalArguments
                    .add(req.request.uri.queryParameters[qvalue]);
              } else {
                if (rp.required) {
                  throw new RequiredError(
                      "${qvalue} not found on the queryParameters");
                } else {
                  positionalArguments.add(rp.defaultValue);
                }
              }
            }
          }
        }
      }
    }
    if (positionalArguments.isEmpty && mv.parameters.length == 2) {
      positionalArguments = [req, model];
    }
    return positionalArguments;
  }
}

/**
 * When a request parameter is been required this will be thrown.
 */
class RequiredError extends Error {
  final String message;
  RequiredError(this.message);
  String toString() => "Required: $message";
}

/**
 * When a response is already done by a responseBody or RestController.
 */
class ResponseDone {}
